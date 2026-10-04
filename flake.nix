{
  description = "Objective-C runtime bindings for Zig";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    zig.url = "github:mitchellh/zig-overlay";

    # Used for shell.nix
    flake-compat = {
      url = github:edolstra/flake-compat;
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  } @ inputs: let
    overlays = [
      # Other overlays
      (final: prev: {
        zigpkgs = inputs.zig.packages.${prev.system};
      })
    ];

    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
  in
    flake-utils.lib.eachSystem systems (
      system: let
        pkgs = import nixpkgs {inherit overlays system;};
        archive = {
          x86_64-linux = {target = "x86_64-linux"; sha256 = "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026";};
          aarch64-linux = {target = "aarch64-linux"; sha256 = "9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8";};
          x86_64-darwin = {target = "x86_64-macos"; sha256 = "4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6";};
          aarch64-darwin = {target = "aarch64-macos"; sha256 = "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a";};
        }.${system};
        zig017 = pkgs.stdenvNoCC.mkDerivation {
          pname = "zig";
          version = "0.17.0";
          src = pkgs.fetchurl {
            url = "https://github.com/cataggar/zig/releases/download/v0.17.0/zig-${archive.target}-0.17.0.tar.xz";
            inherit (archive) sha256;
          };
          dontConfigure = true;
          dontBuild = true;
          installPhase = ''
            mkdir -p "$out/bin" "$out/lib/zig"
            cp -r lib/. "$out/lib/zig/"
            cp zig "$out/bin/zig"
          '';
        };
      in rec {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            zig017
          ];
        };

        # For compatibility with older versions of the `nix` binary
        devShell = self.devShells.${system}.default;
      }
    );
}
