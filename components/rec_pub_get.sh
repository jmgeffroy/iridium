#!/bin/bash
folders=("commons"
  "lcp"
#  "lcp_native"
  "navigator"
  "opds"
  "server"
  "shared"
  "streamer"
  #  "pdfium_ffi"
)
for i in "${folders[@]}"; do
  echo "flutter pub get $i"
  (cd "$i" || exit; flutter pub get)
done
