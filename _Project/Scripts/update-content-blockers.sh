#!/bin/bash
# Regenerates the bundled ad/tracker blocking rules (Browser/ContentBlockers/*.json).
#
# Downloads the filter lists uBlock Origin uses and converts them to WebKit content blocker JSON
# with AdGuard's SafariConverterLib. WebKit compiles each JSON file into a content rule list on
# the device; a list may hold at most 150,000 rules, so the filters are split into two lists.
# Exceptions only apply within their own list, so uBlock's "unbreak" fixes go with the ad rules.
#
# Usage: _Project/Scripts/update-content-blockers.sh
# Set CONVERTER_TOOL to an existing ConverterTool binary to skip building it.

set -euo pipefail

CONVERTER_VERSION="v4.3.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/../Browser/ContentBlockers"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/content-blockers.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

if [[ -z "${CONVERTER_TOOL:-}" ]]; then
    echo "Building AdGuard SafariConverterLib ${CONVERTER_VERSION}..."
    git clone --quiet --depth 1 --branch "${CONVERTER_VERSION}" \
        https://github.com/AdguardTeam/SafariConverterLib.git "${WORK_DIR}/SafariConverterLib"
    swift build --package-path "${WORK_DIR}/SafariConverterLib" -c release --product ConverterTool > /dev/null
    CONVERTER_TOOL="${WORK_DIR}/SafariConverterLib/.build/release/ConverterTool"
fi

download() {
    echo "Downloading $1" >&2
    curl --fail --silent --show-error --location "$1"
    echo
}

convert() {
    local name="$1"
    shift
    local input="${WORK_DIR}/${name}.txt"
    : > "${input}"
    for url in "$@"; do
        download "${url}" >> "${input}"
    done
    "${CONVERTER_TOOL}" convert \
        --input-path "${input}" \
        --safari-rules-json-path "${OUTPUT_DIR}/${name}.json" \
        --advanced-blocking-rules-path "${WORK_DIR}/${name}-advanced.txt" > /dev/null
    echo "Wrote ${name}.json ($(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "${OUTPUT_DIR}/${name}.json") rules)"
}

mkdir -p "${OUTPUT_DIR}"

convert ads \
    https://easylist.to/easylist/easylist.txt \
    https://ublockorigin.github.io/uAssets/filters/filters.txt \
    https://easylist-downloads.adblockplus.org/advblock+cssfixes.txt \
    https://ublockorigin.github.io/uAssets/filters/unbreak.txt

convert privacy \
    https://easylist.to/easylist/easyprivacy.txt
