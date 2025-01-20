# Asset generation pipeline using Nix, which generates a directory structure to be served via obelisk-asset-serve-*

{ nixpkgs }:

with nixpkgs.lib;

rec {

# Default encoding generation function for this platform; usually zopfliEncodings, but gzipEncodings on darwin due to zopfli not building on darwin.
#
# defaultEncodings :: Derivation
defaultEncodings =
  if nixpkgs.stdenv.isDarwin then gzipEncodings else zopfliEncodings;

# Encoding generation function which uses zopfli to encode the asset with very high compression efficiency, at the cost of CPU time compressing.
# Generates gzip, compress/zlib, and deflate outputs all using zopfli with 5 iterations.
#
# zopfliEncodings :: Derivation
zopfliEncodings =
  let zopfli = "${nixpkgs.zopfli}/bin/zopfli"; in
  nixpkgs.writeScriptBin "encode" ''
    #! ${nixpkgs.bash}/bin/bash
    set -eu

    mkdir -p $2
    cp "$1" "$2/identity"

    ${zopfli} -c --i5 --gzip "$1" >"$2/gzip"
    ${zopfli} -c --i5 --zlib "$1" >"$2/compress"
    ${zopfli} -c --i5 --deflate "$1" >"$2/deflate"
  '';

# Encoding generation function which uses gzip to encode the asset with decent compression efficiency and a small CPU cost. Only generates a gzip output.
#
# gzipEncodings :: Derivation
gzipEncodings =
  let gzip = "${nixpkgs.gzip}/bin/gzip"; in
  nixpkgs.writeScriptBin "encode" ''
    #! ${nixpkgs.bash}/bin/bash
    set -eu

    mkdir -p $2
    cp "$1" "$2/identity"

    ${gzip} -c7 "$1" > "$2/gzip"
  '';

# Encoding generation function which doesn't do any compression.
#
# noEncodings :: Derivation
noEncodings =
  nixpkgs.writeScriptBin "encode" ''
    #! ${nixpkgs.bash}/bin/bash
    set -eu

    mkdir -p $2
    cp $1 $2/identity
  '';

# Read a directory structure recursively into a @DirTree@.
#
# @
# type DirTree = AttrSet ({ type : "directory", contents : DirTree } | { type : String, path : String })
# @
#
# readDirRecursive :: String -> DirTree
readDirRecursive = dir:
  let d = filterAttrs (n: d: !(hasPrefix "." n)) (builtins.readDir dir);
      go = name:
        let path = dir + "/${name}";
            type = d.${name};
        in if type == "directory" then {
          inherit name;
          value = {
            inherit type;
            contents = readDirRecursive path;
          };
        } else {
          inherit name;
          value = {
            inherit type path;
          };
        };
  in builtins.listToAttrs (map go (builtins.attrNames d));

# Encode an asset.
#
# encodeAssetWith ::
#   -- | Encoder derivation.
#   --
#   -- See @{no,gzip,zopfli}Encodings@.
#   Derivation ->
#
#   -- | Output derivation.
#   --
#   -- Directory structure:
#   --
#   -- @
#   -- $out
#   -- +-- type
#   -- +-- encodings/
#   -- @
#   --
#   -- * The `type` file contains the string "immutable"
#   -- * The `encodings/` directory contains the encodings produced by the encoder.
#   Derivation
encodeAssetWith = encode:
  nixpkgs.writeScriptBin "encodeAsset" ''
    #! ${nixpkgs.bash}/bin/bash
    set -eu

    inFile=$1
    outDir=$2
    nameWithHash="$(${nixpkgs.nix}/bin/nix-hash --flat --base32 --type sha256 "$inFile" | tr -d '\n')-$(basename "$inFile")"

    echo -n "$nameWithHash" > "$outDir"/nameWithHash

    immutableDir="$outDir"/immutable
    mkdir -p "$immutableDir"
    echo -n "immutable" > "$immutableDir"/type
    ${encode}/bin/encode "$inFile" "$immutableDir"/encodings
  '';

# Encode each file in a @DirTree@, replacing its @path@ attribute with a @drv@ holding the encoded file's derivation.
#
# @
# type AssetTree = AttrSet ({ type : "directory", contents : AssetTree } | { type : String, drv : Derivation })
# @
#
# dirTreeToAssetTree :: DirTree -> AssetTree
dirTreeToAssetTree =
  encode:
  builtins.mapAttrs (k: v:
    if v.type == "directory"
    then {
      type = v.type;
      contents = dirTreeToAssetTree encode v.contents;
    }
    else {
      type = v.type;
      drv = nixpkgs.stdenv.mkDerivation {
        name = "encoding";

        input = v.path;
        unpackPhase = "true";

        buildInputs = [ (encodeAssetWith encode) ];
        buildPhase = "true";
        installPhase = ''
          mkdir -p $out
          encodeAsset "$input" "$out"
        '';
      };
    }
  );

# Given an encoding generation function to use and a directory containing assets, recursively walk the directory and encode each asset.
#
# mkAssetsWith :: Derivation -> String -> Derivation
mkAssetsWith =
  encode: dir:
  let
    tree =
      nixpkgs.writeText "tree.json"
        (builtins.toJSON (dirTreeToAssetTree encode (readDirRecursive dir)));
  in
  nixpkgs.stdenv.mkDerivation {
    name = "encodings";
    
    inherit tree;
    unpackPhase = "true";

    buildInputs = [
      (nixpkgs.writeScriptBin "link-encodings.py" ''
        #! ${nixpkgs.python3}/bin/python3
        import json
        from pathlib import Path
        import os

        out = os.environ["out"]
        Path(out).mkdir()
        os.chdir(out)

        with open(os.environ["tree"]) as f:
          tree = json.load(f)

        def go(tree):
          for k, v in tree.items():
            if v["type"] == "directory":
              Path(k).mkdir()
              os.chdir(k)
              go(v["contents"])
              os.chdir("..")
            else:
              with open(os.path.join(v["drv"], "nameWithHash")) as nameWithHashFile:
                nameWithHash = nameWithHashFile.read()
              
              os.symlink(os.path.join(v["drv"], "immutable"), os.path.join(os.getcwd(), nameWithHash))

              Path(k).mkdir()

              with open(os.path.join(k, "target"), "w") as target:
                target.write(nameWithHash)
              
              with open(os.path.join(k, "type"), "w") as type:
                type.write("redirect")

        go(tree)
      '')
    ];
    buildPhase = "true";

    installPhase = ''
      link-encodings.py
    '';
  };

# Given an input directory containing assets, recursively walk the directory and encode each asset with the default encodings.
#
# mkAssets :: String -> Derivation
mkAssets = mkAssetsWith defaultEncodings;

}
