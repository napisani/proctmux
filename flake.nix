{
  description = "A Nix flake for building and developing the proctmux cli tool";

  # Nixpkgs / NixOS version to use.
  inputs = {
    nixpkgs.url =
      "github:NixOS/nixpkgs/648f70160c03151bc2121d179291337ad6bc564b";
    flake-utils.url = "github:numtide/flake-utils";
    goflake.url = "github:sagikazarmark/go-flake";
    goflake.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, goflake, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Use go_1_24 instead of the default go package
        go = pkgs.go_1_24;
        buildDeps = with pkgs; [ git go gnumake ];
        devDeps = with pkgs; buildDeps ++ [ gotools goreleaser ];

        # Generate a user-friendly version number.
        version = builtins.substring 0 8 self.lastModifiedDate;

      in {
        packages.default = pkgs.buildGoModule {
          pname = "proctmux";
          inherit version;
          # Use Go 1.24 instead of default Go
          go = go;
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

          vendorHash = "sha256-Md8d9cSv4EaHbdARfXE7sLdqq1uveCH+3rfZqufB4tA=";
        };

        devShells.default = pkgs.mkShell {
          # Use Go 1.24
          inherit go;
          buildInputs = devDeps;

          # # Ensure Go from buildInputs is available on PATH
          # nativeBuildInputs = [ pkgs.go ];

          # # Set Go-related environment variables
          # shellHook = ''
          #   export PATH=$PATH:$(go env GOPATH)/bin
          #   export GOPATH=$(go env GOPATH)
          #   export GOROOT=$(go env GOROOT)
          # '';
        };
      });
}
