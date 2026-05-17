use thiserror::Error;

#[allow(dead_code)]
pub type Result<T> = ::std::result::Result<T, Error>;

#[allow(dead_code)]
#[derive(Debug, Error)]
pub enum Error {
  #[error("some error: '{0}'")]
  SomeError(String),
}
