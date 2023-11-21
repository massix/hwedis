{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
  in {
    devShells."${system}".default = with pkgs; mkShell rec {
      nativeBuildInputs = [ ghc cabal-install zlib websocat ];

      LD_LIBRARY_PATH = lib.makeLibraryPath nativeBuildInputs;
    };
  };
}

