# V8 pin for codex. `version` must match the `v8` crate in codex-rs/Cargo.lock;
# the hashes come from the matching `rusty-v8-v${version}` release on
# openai/codex (see fetchers.nix for why it is not denoland/rusty_v8).
{ fetchRustyV8 }:

fetchRustyV8 {
  version = "150.4.0";
  archiveShas = {
    x86_64-linux = "sha256-o1x10fJuapg4haRbM0kKTr5U8FBQVosyuJz7QhswtYM=";
    aarch64-linux = "sha256-0VF+7UBUaFNwKbAF1f6ZfsdNXI01H5FrOm3yC30oEbo=";
    aarch64-darwin = "sha256-AK27SHmISMd1UEQcaGc6XoUpuOG3PqvN7iMss5tA9KE=";
  };
  srcBindingShas = {
    x86_64-linux = "sha256-dyeCauR5vbZF6Acjn7EtH44uI956bPFvXuWSaQ0dhQY=";
    aarch64-linux = "sha256-dyeCauR5vbZF6Acjn7EtH44uI956bPFvXuWSaQ0dhQY=";
    aarch64-darwin = "sha256-ylrfDPicmnCtRgrnNkiy/om3SqETs8t/dXtqArdYOU8=";
  };
}
