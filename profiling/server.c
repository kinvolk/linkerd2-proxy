#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#include <sys/select.h>

void error(const char *msg) {
  perror(msg);
  exit(EXIT_FAILURE);
}

#define MAX_CONNECTIONS 512
#define MAX_HEADER_LEN 2048

typedef enum
{
  INITIAL,

  SEND_RESPONSE_HEADER,
  SEND_RESPONSE_HEADER_ONLY, // omit content for 400 Bad Request or 404 Not Found
  SEND_RESPONSE_CONTENT,

  POST_RECV_CONTENT,
} HTTPState;

static int
is_reading (HTTPState s)
{
  return s == INITIAL || s == POST_RECV_CONTENT;
}

static int
is_writing (HTTPState s)
{
  return s == SEND_RESPONSE_HEADER || s == SEND_RESPONSE_HEADER_ONLY ||
         s == SEND_RESPONSE_CONTENT;
}

typedef struct
{
  int socket_fd; // != 0 -> active
  HTTPState http_state;
  char recv_header_buf[MAX_HEADER_LEN]; // incoming header, zero-terminated
  char send_header_buf[MAX_HEADER_LEN]; // outgoing header, zero-terminated
  ssize_t sent_header; // how much of the header was sent out
  ssize_t recv_content_remaining; // how much of the POST content needs to be received
  int file_fd;
} SocketState;


void
resp (SocketState *state, char *status, ssize_t content_length, fd_set *read_fds, fd_set *write_fds)
{
  state->http_state = SEND_RESPONSE_HEADER_ONLY;
  FD_SET(state->socket_fd, write_fds); // register socket for writing
  FD_CLR(state->socket_fd, read_fds); // will not read anymore
  snprintf(state->send_header_buf, sizeof (state->send_header_buf),
           "HTTP/1.0 %s\r\nContent-Length: %ld\r\nConnection: close\r\n\r\n", status, content_length);
}

void
close_socket (SocketState *state, fd_set *read_fds, fd_set *write_fds)
{
  if (state->socket_fd != 0)
    {
      close (state->socket_fd);
    }
  FD_CLR (state->socket_fd, read_fds);
  FD_CLR (state->socket_fd, write_fds);
  if (state->file_fd != 0 && state->file_fd != -1)
    {
      close (state->file_fd);
    }
  memset (state, 0, sizeof (SocketState));
}

void
http_answer (SocketState *state, char *p, int post, int header_len_before_read, ssize_t read_bytes,
             ssize_t post_content_length, char *filename, fd_set *read_fds, fd_set *write_fds)
{
  int non_header_bytes;

  non_header_bytes = state->recv_header_buf + header_len_before_read + read_bytes - p;

  if (strstr(filename, "../") != NULL)
    {
      resp (state, "403 Forbidden", 0, read_fds, write_fds);
      return;
    }
  else if (post && (post_content_length == -1 || non_header_bytes > post_content_length))
    {
      resp (state, "400 Bad Request", 0, read_fds, write_fds);
      return;
    }
  else
    {
      state->file_fd = open (filename, post ? O_CREAT|O_RDWR|O_TRUNC : O_RDONLY , S_IRUSR|S_IWUSR);
    }

  if (state->file_fd == -1)
    {
      resp (state, "404 Not Found", 0, read_fds, write_fds);
    }
  else if ((read (state->file_fd, NULL, 0) == -1 && errno == EISDIR))
    {
      close (state->file_fd);
      resp (state, "404 Not Found", 0, read_fds, write_fds);
    }
  else if (post)
    {
      int written;

      state->recv_content_remaining = post_content_length - non_header_bytes;
      while (non_header_bytes > 0)
        {
          written = write (state->file_fd, p, non_header_bytes);
          if (written == -1 && errno != EINTR)
            {
              printf ("initial post write error\n");
              close_socket (state, read_fds, write_fds);
              break;
            }
          else if (written > 0)
            {
              non_header_bytes -= written;
              p += written;
            }
        }
      state->http_state = POST_RECV_CONTENT;
      if (state->recv_content_remaining == 0)
        {
          close (state->file_fd);
          resp (state, "200 OK", 0, read_fds, write_fds);
        }
    }
  else // GET
    {
      ssize_t content_length;

      content_length = lseek(state->file_fd, 0L, SEEK_END);
      lseek(state->file_fd, 0L, SEEK_SET);
      resp (state, "200 OK", content_length, read_fds, write_fds);
      state->http_state = SEND_RESPONSE_HEADER; // overwrite next state
    }
}

void
http_initial_state (SocketState *state, fd_set *read_fds, fd_set *write_fds)
{
  ssize_t read_bytes;
  int header_len_before_read;

  header_len_before_read = strlen (state->recv_header_buf);
  read_bytes = read (state->socket_fd, state->recv_header_buf + header_len_before_read,
                     sizeof (state->recv_header_buf) - header_len_before_read - 1);
  if (read_bytes == 0)
    {
      printf ("eof: Bad Request\n");
      // unexpected end of stream
      resp (state, "400 Bad Request", 0, read_fds, write_fds);
    }
  else if (read_bytes == -1 && errno != EWOULDBLOCK && errno != EINTR)
    {
      printf ("read error\n");
      close_socket (state, read_fds, write_fds);
    }
  else if (read_bytes > 0) // assemble header and parse it until recognized as complete
    {
      int valid = 1, complete = 0, post = 0;
      char *p = state->recv_header_buf;
      char filename[256];
      ssize_t post_content_length = -1;

      if (strncasecmp (p, "GET ", 4) == 0)
        {
          p += 4;
        }
      else if (strncasecmp (p, "POST ", 5) == 0)
        {
          p += 5;
          post = 1;
        }
      else if (strlen (p) > 4)
        {
          valid = 0;
        }
      // parse requested path
      if (valid)
        {
          char *pathend;

          pathend = strstr (p, " HTTP/1.0\r\n");

          if (pathend != NULL && pathend - p < sizeof (filename) - 2 && *p == '/')
            {
              memset (filename, 0, sizeof (filename));
              filename[0] = '.'; // relative path, zero-terminated, thus len - 2
              strncpy (filename+1, p, pathend - p);
              p = strstr (p, "\r\n") + 2; // continue with next line
              // process HTTP header lines
              while (1) // search until end of header
                {
                  int strl;

                  if (strstr (p, "\r\n") == p)
                    {
                      p += 2;
                      complete = 1;
                      break;
                    }

                  strl = strlen ("Content-Length: ");
                  if (strncasecmp (p, "Content-Length: ", strl) == 0)
                    {
                      post_content_length = atoi (p + strl);
                      if (post_content_length < 0)
                        {
                          valid = 0;
                          break;
                        }
                    }

                  p = strstr (p, "\r\n");
                  if (p == NULL)
                    {
                      // need to receive more
                      break;
                    }
                  p += 2; // next line
                }
            }
          else if (strstr (p, "\r\n") > p)
            {
              valid = 0;
            }
        }

      if (complete)
        {
          http_answer (state, p, post, header_len_before_read, read_bytes, post_content_length, filename, read_fds, write_fds);
        }
      else if (valid == 0 ||
               strlen (state->recv_header_buf) == sizeof (state->recv_header_buf) - 1)
        {
          // invalid or maximal header length reached
          resp (state, "400 Bad Request", 0, read_fds, write_fds);
        }
    }
}

void
http_recv_post (SocketState *state, fd_set *read_fds, fd_set *write_fds)
{
  ssize_t read_bytes;
  char copybuf[2048];

  read_bytes = read (state->socket_fd, copybuf, sizeof (copybuf));
  if (read_bytes == 0 || read_bytes > state->recv_content_remaining)
    {
      printf ("post (eof or too much): wrong POST content amount\n");
      // unexpected end of stream or too much
      close (state->file_fd);
      resp (state, "400 Bad Request", 0, read_fds, write_fds);
    }
  else if (read_bytes == -1 && errno != EWOULDBLOCK && errno != EINTR)
    {
      printf ("read error\n");
      close_socket (state, read_fds, write_fds);
    }
  else if (read_bytes > 0)
    {
      int written, left = read_bytes;

      state->recv_content_remaining -= read_bytes;
      while (left > 0)
        {
          written = write (state->file_fd, copybuf + (read_bytes - left), left);
          if (written == -1 && errno != EINTR)
            {
              printf ("file chunk write error\n");
              close_socket (state, read_fds, write_fds);
              break;
            }
          else if (written > 0)
            {
              left -= written;
            }
        }

      if (state->recv_content_remaining == 0)
        {
          close (state->file_fd);
          resp (state, "200 OK", 0, read_fds, write_fds);
        }
    }
}

void
http_send_header (SocketState *state, fd_set *read_fds, fd_set *write_fds)
{
  ssize_t written_bytes;
  char copybuf[2048];

  written_bytes = write (state->socket_fd, state->send_header_buf,
                         strlen (state->send_header_buf) - state->sent_header);
  if (written_bytes == -1 && errno == EPIPE)
    {
      printf ("write error: socket closed\n");
      // socket was closed to early
      close_socket (state, read_fds, write_fds);
    }
  else if (written_bytes == -1 && errno != EWOULDBLOCK && errno != EINTR)
    {
      printf ("write error\n");
      close_socket (state, read_fds, write_fds);
    }
  else if (written_bytes > 0)
    {
      state->sent_header += written_bytes;
      if (state->sent_header == strlen (state->send_header_buf))
        {
          if (state->http_state == SEND_RESPONSE_HEADER_ONLY)
            {
              close_socket (state, read_fds, write_fds);
            }
          else
            {
              state->http_state = SEND_RESPONSE_CONTENT;
            }
        }
    }
}

void
http_send_content (SocketState *state, fd_set *read_fds, fd_set *write_fds)
{
  ssize_t read_file_bytes, written_bytes;
  char copybuf[2048];

  read_file_bytes = read (state->file_fd, copybuf, sizeof (copybuf));
  if (read_file_bytes == -1 && errno != EINTR)
    {
      printf ("file read error\n");
      close_socket (state, read_fds, write_fds);
    }
  else if (read_file_bytes == 0)
    {
      // finished sending
      close_socket (state, read_fds, write_fds);
    }
  else if (read_file_bytes > 0)
    {
      written_bytes = write (state->socket_fd, copybuf, read_file_bytes);
      if (written_bytes == -1 && errno == EPIPE)
        {
          printf ("write error (content): socket closed\n");
          // socket was closed to early
          close_socket (state, read_fds, write_fds);
        }
      else if (written_bytes == -1 && errno != EWOULDBLOCK && errno != EINTR)
        {
          printf ("write error\n");
          close_socket (state, read_fds, write_fds);
        }
      else if (written_bytes > 0)
        {
          if (written_bytes < read_file_bytes)
            {
              if (lseek(state->socket_fd, written_bytes - read_file_bytes, SEEK_CUR) == -1)
                {
                  printf ("seek error\n");
                  close_socket (state, read_fds, write_fds);
                }
            }
        }
    }
}

void
serve_connection (SocketState *state, fd_set *read_fds, fd_set *write_fds, fd_set *read_fds_copy, fd_set *write_fds_copy)
{
  if (state->socket_fd != 0 &&
      FD_ISSET (state->socket_fd, read_fds_copy) &&
      is_reading (state->http_state)) // read HTTP requests
    {
      switch (state->http_state)
        {
        case INITIAL:
          http_initial_state (state, read_fds, write_fds);
          break;
        case POST_RECV_CONTENT:
          http_recv_post (state, read_fds, write_fds);
          break;
        default:
          error ("case mismatch when reading");
          break;
        }
    }
  else if (state->socket_fd != 0 &&
      FD_ISSET (state->socket_fd, write_fds_copy) &&
      is_writing (state->http_state)) // write HTTP response
    {
      switch (state->http_state)
        {
        case SEND_RESPONSE_HEADER:
        case SEND_RESPONSE_HEADER_ONLY:
          http_send_header (state, read_fds, write_fds);
          break;
        case SEND_RESPONSE_CONTENT:
          http_send_content (state, read_fds, write_fds);
          break;
        default:
          error ("case mismatch when writing");
          break;
        }
    }
}

void
select_server (int port)
{
  int sockfd_listen, maxfd, yes = 1;
  fd_set read_fds, read_fds_copy, write_fds, write_fds_copy;
  struct sockaddr_in server_addr;
  SocketState states[MAX_CONNECTIONS];

  memset (&server_addr, 0, sizeof (server_addr));
  memset (states, 0, sizeof (states));

  signal (SIGPIPE, SIG_IGN);

  sockfd_listen = socket (AF_INET, SOCK_STREAM, 0);
  if (sockfd_listen < 0 ||
      setsockopt (sockfd_listen, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof (int)) < 0)
    {
      error ("Error initializing socket");
    }

  server_addr.sin_family = AF_INET;
  server_addr.sin_addr.s_addr = INADDR_ANY;
  server_addr.sin_port = htons (port);

  if (bind (sockfd_listen, (struct sockaddr *) &server_addr, sizeof (server_addr)) != 0)
    {
      error("Error on binding");
    }
  if (listen (sockfd_listen, 5) == -1)
    {
      error ("Error on listening");
    }
  if (fcntl (sockfd_listen, F_SETFD, O_NONBLOCK) == -1)
    {
      error ("Error setting socket to non-blocking mode");
    }

  FD_ZERO (&read_fds);
  FD_ZERO (&write_fds);
  FD_SET (sockfd_listen, &read_fds);
  maxfd = sockfd_listen;

  while (1)
    {
      int i, nready, can_accept_at = -1;

      // reset FD masks
      memcpy (&read_fds_copy, &read_fds, sizeof (read_fds));
      memcpy (&write_fds_copy, &write_fds, sizeof (write_fds));
      nready = select (maxfd+1, &read_fds_copy, &write_fds_copy, NULL, NULL);
      if (nready == -1 && errno == EINTR)
        {
          continue; // system call got interrupted
        }
      else if (nready == -1)
        {
          error("Select error");
        }

      for (i = 0; i < MAX_CONNECTIONS; i++)
        {
          if (states[i].socket_fd == 0) {
            can_accept_at = i;
            break;
          }
        }

      // accept new connections
      if (FD_ISSET (sockfd_listen, &read_fds_copy) && can_accept_at != -1)
        {
          int sockfd_client;

          nready--;
          sockfd_client = accept(sockfd_listen, NULL, NULL);
          if (sockfd_client == -1)
            {
              // retry next in next run
            }
          else
            {
              if (fcntl (sockfd_client, F_SETFD, O_NONBLOCK) == -1)
                {
                  error ("Error setting accepted socket to non-blocking mode");
                }

              FD_SET(sockfd_client, &read_fds); // register socket for listening
              if (sockfd_client > maxfd)
                {
                  maxfd = sockfd_client;
                }

              states[can_accept_at].socket_fd = sockfd_client;
              states[can_accept_at].http_state = INITIAL;
            }
        }

      // process connections
      for (i = 0; i < MAX_CONNECTIONS && nready > 0; i++)
        {
          serve_connection (&states[i], &read_fds, &write_fds, &read_fds_copy, &write_fds_copy);
        }
    }

  close (sockfd_listen);
}

int
main (int argc, char *argv[])
{
  if (argc < 3 || strcmp (argv[1], "-p") != 0)
    {
      printf ("Usage: %s -p <port>\nServes and creates files under the current directory, no URL encoding supported\n", argv[0]);
      exit (EXIT_FAILURE);
    }

  select_server (atoi (argv[2]));
  exit (EXIT_SUCCESS);
}

