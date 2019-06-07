use actix_rt;
use actix_http::{HttpService, KeepAlive};
use actix_server::Server;
use actix_web::dev::Body;
use actix_web::http::header::{CONTENT_TYPE, SERVER};
use actix_web::http::{HeaderValue, StatusCode};
use actix_web::{web, App, HttpResponse};
use bytes::{BufMut, Bytes, BytesMut};
use std::io;

pub struct Writer<'a>(pub &'a mut BytesMut);

impl<'a> io::Write for Writer<'a> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.put_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn plaintext() -> HttpResponse {
    let mut res = HttpResponse::with_body(
        StatusCode::OK,
        Body::Bytes(Bytes::from_static(b"Hello, World!\n")),
    );
    res.headers_mut()
        .insert(SERVER, HeaderValue::from_static("Actix"));
    res.headers_mut()
        .insert(CONTENT_TYPE, HeaderValue::from_static("text/plain"));
    res
}

fn main() -> std::io::Result<()> {
    let sys = actix_rt::System::new("demo");

    Server::build()
        .backlog(1024)
        .bind("demo", "127.0.0.1:8080", || {
            HttpService::build().keep_alive(KeepAlive::Os).h1(App::new()
                .service(web::resource("/").to(plaintext)))
        })?
        .start();

    println!("Started http server: 127.0.0.1:8080");
    sys.run()
}
