use thiserror::Error;

#[allow(dead_code)]
pub type Result<T> = ::std::result::Result<T, {{crate_name | pascal_case}}Error>;

#[allow(dead_code)]
#[derive(Debug, Error)]
pub enum {{crate_name | pascal_case}}Error {
    #[error("some error: '{0}'")]
    SomeError(String),
}
