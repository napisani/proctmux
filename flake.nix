{
  description = "A Nix flake for building and developing the proctmux cli tool";

  # Nixpkgs / NixOS version to use.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    agent-tui-src = {
      url = "github:pproenca/agent-tui";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      zig-overlay,
      agent-tui-src,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        zig = zig-overlay.packages.${system}."0.16.0";

        agent-tui = pkgs.rustPlatform.buildRustPackage {
          pname = "agent-tui";
          version = "1.0.2";
          src = "${agent-tui-src}/cli";
          cargoLock.lockFile = "${agent-tui-src}/cli/Cargo.lock";
          cargoBuildFlags = [
            "-p"
            "agent-tui"
            "--ignore-rust-version"
          ];
          doCheck = false;
          AGENT_TUI_VERSION = "1.0.2";
          AGENT_TUI_GIT_SHA = builtins.substring 0 12 agent-tui-src.rev;
        };
        buildDeps = with pkgs; [
          git
          gnumake
          python3
          python3Packages.pytest
          tmux
          zig
          agent-tui
        ];

        version = "1.0.0";

      in
      {
        packages.agent-tui = agent-tui;
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "proctmux";
          inherit version;
          src = lib.cleanSource ./.;

          nativeBuildInputs = with pkgs; [
            gnumake
            zig
          ];

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild
            make build BUILD_CACHE_DIR="$TMPDIR/zig-cache" VERSION=v${version}
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm755 bin/proctmux "$out/bin/proctmux"
            runHook postInstall
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = buildDeps;
        };
      }
    );
}
