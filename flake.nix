{
  description = "litem8 - SQLite migration tool";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    zig2nix.url = "github:Cloudef/zig2nix";
  };

  outputs = inputs @ { flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem = { self', system, lib, ... }:
        let
          env = inputs.zig2nix.outputs.zig-env.${system} {
            zig = inputs.zig2nix.outputs.packages.${system}.zig-0_15_2;
          };
          pkgs = env.pkgs;
        in
        {
          packages = {
            litem8 = env.package {
              src = lib.cleanSource ./.;

              # No external dependencies - SQLite is bundled
              nativeBuildInputs = [ ];
              buildInputs = [ ];

              meta = {
                description = "SQLite migration tool - self-contained with bundled SQLite";
                mainProgram = "litem8";
              };
            };

            default = self'.packages.litem8;
          };

          apps = {
            litem8 = {
              type = "app";
              program = lib.getExe self'.packages.litem8;
            };
            default = self'.apps.litem8;
          };

          devShells.default = env.mkShell {
            nativeBuildInputs = [ ];
          };
        };
    };
}
