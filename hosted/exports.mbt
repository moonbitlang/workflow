///|
/// Read an opaque host-specific top-level field from the handoff.
/// OpenSeek workflows use this to read their `openseek` audit input.
/// Reserved handoff fields are excluded. Missing fields return `None`;
/// an explicit JSON null is returned as `Some(Null)`.
pub fn Context::extension(self : Context, name : String) -> Json? {
  self.extensions.get(name)
}
