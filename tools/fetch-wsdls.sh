#!/usr/bin/env bash
# AT's published WSDLs, as gobl.pt.saft (Apache-2.0) keeps them, and the EU's VIES WSDL, each checked by hash into .wsdls/. Not
# committed here: their terms of reuse aren't stated. VIES is fetched live and may change, so a change there only skips it.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=${1:-$root/.wsdls}
mkdir -p "$out"
gobl=https://raw.githubusercontent.com/invopop/gobl.pt.saft/718aa3a3b379d2cd8b6794846e004caa24c1af48/atws/schemas

fetch() { # name url hash required
    local file=$out/$1
    if [[ ! -f $file ]] || ! echo "$3  $file" | sha256sum -c --status; then
        curl -fsSL --max-time 60 -o "$file.new" "$2" || { [[ $4 == no ]] && { echo "skipping $1: not reachable" >&2; return 0; }; exit 1; }
        mv "$file.new" "$file"
    fi
    if ! echo "$3  $file" | sha256sum -c --status; then
        if [[ $4 == no ]]; then
            echo "skipping $1: it has changed" >&2
            rm "$file"
            return 0
        fi
        echo "$1 isn't what was checked: $(sha256sum "$file")" >&2
        exit 1
    fi
}

fetch series.wsdl "$gobl/Comunicacao_Series.wsdl" eda5a19f435d0fc5f467177c14af77333b6358b2ed7ad96fe363f9e0ca73f03a yes
fetch transporte.wsdl "$gobl/documentosTransporte.wsdl" c7f1ee1e063731c6b028c9e534be6b26bd0f90291083789376b341fbe631089b yes
fetch fatcore.wsdl "$gobl/Fatcorews.wsdl" 1d9c3391d81c419b5f000ab509321b6bf184500cbc2c611b4a438dc8fa3f2eba yes
fetch fatshare.wsdl https://info.portaldasfinancas.gov.pt/pt/apoio_ao_contribuinte/Outras_entidades/Suporte_tecnologico/Webservice/e_Fatura/Documents/fatshareInvoices.wsdl 4cee9cf69081445e0360a10682c6c22bab262e3b7da2caf9aff805a1681c4d9d yes
fetch vies.wsdl https://ec.europa.eu/taxation_customs/vies/checkVatService.wsdl a5de093d23585cb3ff4d6c2a4367ba6003de48b428e30bb99548f2d184829279 no
