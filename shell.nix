# shell.nix
{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  buildInputs = with pkgs; [
    pkgsCross.riscv32-embedded.buildPackages.gcc
    spike
    verilator
    gtkwave
    python3
    autoconf
    automake
    gnumake
    yosys
    nextpnr
    trellis
    openfpgaloader
  ];
}
