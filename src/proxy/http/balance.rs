extern crate hyper_balance;
extern crate tower_balance;
extern crate tower_discover;

use std::marker::PhantomData;
use std::time::Duration;
use std::{cmp, hash};

use futures::{Future, Poll};
use hyper::body::Payload;

use self::tower_discover::Discover;

pub use self::hyper_balance::{PendingUntilFirstData, PendingUntilFirstDataBody};
use self::tower_balance::{choose::PowerOfTwoChoices, load::WithPeakEwma, Balance, WithWeighted};
pub use self::tower_balance::{HasWeight, Weight, Weighted};

use http;
use svc;

/// Configures a stack to resolve `T` typed targets to balance requests over
/// `M`-typed endpoint stacks.
#[derive(Debug)]
pub struct Layer<K, A, B> {
    decay: Duration,
    default_rtt: Duration,
    _marker: PhantomData<fn(K, A) -> B>,
}

/// Resolves `T` typed targets to balance requests over `M`-typed endpoint stacks.
#[derive(Debug)]
pub struct MakeSvc<M, K, A, B> {
    decay: Duration,
    default_rtt: Duration,
    inner: M,
    _marker: PhantomData<fn(K, A) -> B>,
}

// === impl Layer ===

pub fn layer<K, A, B>(default_rtt: Duration, decay: Duration) -> Layer<K, A, B> {
    Layer {
        decay,
        default_rtt,
        _marker: PhantomData,
    }
}

impl<K, A, B> Clone for Layer<K, A, B> {
    fn clone(&self) -> Self {
        Layer {
            decay: self.decay,
            default_rtt: self.default_rtt,
            _marker: PhantomData,
        }
    }
}

impl<M, K, A, B> svc::Layer<M> for Layer<K, A, B>
where
    A: Payload,
    B: Payload,
{
    type Service = MakeSvc<M, K, A, B>;

    fn layer(&self, inner: M) -> Self::Service {
        MakeSvc {
            decay: self.decay,
            default_rtt: self.default_rtt,
            inner,
            _marker: PhantomData,
        }
    }
}

// === impl MakeSvc ===

impl<M: Clone, K, A, B> Clone for MakeSvc<M, K, A, B> {
    fn clone(&self) -> Self {
        MakeSvc {
            decay: self.decay,
            default_rtt: self.default_rtt,
            inner: self.inner.clone(),
            _marker: PhantomData,
        }
    }
}

impl<T, M, K, A, B> svc::Service<T> for MakeSvc<M, K, A, B>
where
    M: svc::Service<T>,
    M::Response: Discover<Key = Weighted<K>>,
    <M::Response as Discover>::Key: HasWeight,
    <M::Response as Discover>::Service:
        svc::Service<http::Request<A>, Response = http::Response<B>>,
    K: cmp::Eq + hash::Hash,
    A: Payload,
    B: Payload,
{
    type Response = Balance<
        WithWeighted<WithPeakEwma<M::Response, PendingUntilFirstData>, K>,
        PowerOfTwoChoices,
    >;
    type Error = M::Error;
    type Future = MakeSvc<M::Future, K, A, B>;

    fn poll_ready(&mut self) -> Poll<(), Self::Error> {
        self.inner.poll_ready()
    }

    fn call(&mut self, target: T) -> Self::Future {
        let inner = self.inner.call(target);

        MakeSvc {
            inner,
            decay: self.decay,
            default_rtt: self.default_rtt,
            _marker: PhantomData,
        }
    }
}

impl<F, K, A, B> Future for MakeSvc<F, K, A, B>
where
    F: Future,
    F::Item: Discover<Key = Weighted<K>>,
    <F::Item as Discover>::Service: svc::Service<http::Request<A>, Response = http::Response<B>>,
    K: cmp::Eq + hash::Hash,
    A: Payload,
    B: Payload,
{
    type Item =
        Balance<WithWeighted<WithPeakEwma<F::Item, PendingUntilFirstData>, K>, PowerOfTwoChoices>;
    type Error = F::Error;

    fn poll(&mut self) -> Poll<Self::Item, Self::Error> {
        let discover = try_ready!(self.inner.poll());
        let instrument = PendingUntilFirstData::default();
        let loaded = WithWeighted::from(WithPeakEwma::new(
            discover,
            self.default_rtt,
            self.decay,
            instrument,
        ));
        Ok(Balance::p2c(loaded).into())
    }
}
