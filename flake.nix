{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
  in {
    devShells."${system}".default = with pkgs; pkgs.mkShell {
      packages = [ ghc cabal-install zlib insomnia ];
    };
  };
}

