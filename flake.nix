{
  description = "A Nix flake for building and developing the proctmux cli tool";

  # Nixpkgs / NixOS version to use.
  inputs = {
    nixpkgs.url =
      "github:NixOS/nixpkgs/10b813040df67c4039086db0f6eaf65c536886c6";
    flake-utils.url = "github:numtide/flake-utils";
    goflake.url = "github:sagikazarmark/go-flake";
    goflake.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, goflake, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        buildDeps = with pkgs; [ git go gnumake ];
        devDeps = with pkgs; buildDeps ++ [ gotools goreleaser ];

        # Generate a user-friendly version number.
        version = builtins.substring 0 8 self.lastModifiedDate;

      in {
        packages.default = pkgs.buildGoModule {
          pname = "proctmux";
          inherit version;
          # In 'nix develop', we don't need a copy of the source tree
          # in the Nix store.
          src = ./.;

          # This hash locks the dependencies of this package. It is
          # necessary because of how Go requires network access to resolve
          # VCS.  See https://www.tweag.io/blog/2021-03-04-gomod2nix/ for
          # details. Normally one can build with a fake sha256 and rely on native Go
          # mechanisms to tell you what the hash should be or determine what
          # it should be "out-of-band" with other tooling (eg. gomod2nix).
          # To begin with it is recommended to set this, but one must
          # remeber to bump this hash when your dependencies change.
          #vendorSha256 = pkgs.lib.fakeSha256;

          vendorHash = "sha256-5xyEKZG1fogU7M2y+W6UH5pztscu77ZwIyLdGwMjrdU=";
        };

        devShells.default = pkgs.mkShell { buildInputs = devDeps; };
      });
}
