# abla-soap

SOAP for Abla: envelopes and faults for SOAP 1.1 and 1.2, WS-Security, a client on any HTTP client, and typed clients generated
from WSDL 1.1. Written for the Portuguese tax authority's (AT) web services, and not tied to them.

It reads what comes back with [abla-xml](https://github.com/AndreBaltazar8/abla-xml)'s bounded parser, with no DOCTYPE and so no
entities, and it fetches nothing it isn't told to.

| Import | What's in it |
|---|---|
| `github("AndreBaltazar8/abla-soap")` | everything below but `wsdl`, `generate` and `tls`, and abla-xml's names |
| `.../envelope` | `soapWriter`, `soapParse`, `SoapFault`, `soapNotUnderstood` |
| `.../client` | `soapClient`, `SoapCall`, `soapParseUrl` |
| `.../decode` | what generated clients read with |
| `.../wssecurity` | `WsseUsernameToken`, `AtUsernameToken`, `atUsernameToken` |
| `.../wsdl` | `wsdlParse`: the model |
| `.../generate` | `wsdlGenerate`, `wsdlGenerateFrom`: Abla source from it |
| `.../tls` | `soapHttpsClient`, `soapMutualTlsClientPem`, `soapMutualTlsClientPkcs12`. Only a program that imports this links OpenSSL |

## A typed client

```sh
git clone https://github.com/AndreBaltazar8/abla-soap && cd abla-soap && make tool
build/wsdl2abla series.wsdl --prefix AtSeries -o ../myapp/src/at_series.ab
```

Commit what it writes: a reviewable file, which needs no compile-time capability and doesn't change unless you run the tool again.
[Why not at compile time](#why-a-tool).

```abla
import github("AndreBaltazar8/abla-soap")
import github("AndreBaltazar8/abla-soap/tls")
import "at_series.ab"
import "abla/fs"
import "abla/io"

fun main: int {
    val headers: array<SoapHeaderSource> = []
    headers.append(atUsernameToken("599999993/37", password, Path("ChavePublicaAT.pem").readText()))
    val made = soapMutualTlsClientPkcs12(
        "https://servicos.portaldasfinancas.gov.pt:722/SeriesWSService",
        Path("test.pfx").readText(), pfxPassword,
        SoapTlsOptions(headers = headers)
    )
    val soap = made.client
    if (soap == null) {
        eprintln(made.error)
        return 1
    }
    val call = AtSeriesSeriesWSPortBindingClient(soap).registarSerie(AtSeriesRegistarSerie(
        serie = "A", tipoSerie = "N", classeDoc = "SI", tipoDoc = "FT", numInicialSeq = "1",
        dataInicioPrevUtiliz = "2026-11-02", numCertSWFatur = 9999, meioProcessamento = "PI"
    ))
    val answer = call.value
    if (!call.ok() || answer == null) {
        eprintln(call.problem())
        return 1
    }
    println(answer.registarSerieResp.infoResultOper.msgResultOper)
    0
}
```

`SoapTlsOptions.version` is SOAP 1.1 by default; generated code has a `...ClientVersion` for each binding to pass there.

### What it generates

For each complex type, and each element with one of its own, a class, `...WriteContent` and `...Read`; for each SOAP binding, a
`...Client` with a method for each operation, returning a `SoapCall<T>`; for each port, a `...Location`; for each enumeration, a
constant.

| XML Schema | Abla | |
|---|---|---|
| `int`, `long`, `short`, `byte`, unsigned up to `unsignedInt`, and `integer` restricted to 18 digits or fewer | `int` | range checked when read |
| `integer` otherwise, `unsignedLong` | `string` | beyond a long; checked when read. AT's `numInicialSeq` has 25 digits |
| `decimal` | `string` | exact. Nothing here goes through a float; `float` and `double` are text too |
| `boolean` | `bool` | |
| `base64Binary` | `string` of the bytes | |
| other simple types | `string` | facets aren't checked; the server does that |
| `anyType`, `xs:any` | `XmlElement`, `array<XmlElement>` | |
| `minOccurs="0"`, a `choice`'s branch, `nillable` | `T?` | |
| `maxOccurs` over 1 | `array<T>` | |

It reads `sequence`, `all`, `choice`, `group`, `attributeGroup`, `ref`, `complexContent` and `simpleContent` (extended bases are
flattened in), named and anonymous types, recursion, `form`, soap headers named by an operation, one-way operations, document and
rpc literal, and `xs:import`, `xs:include` and `wsdl:import` through a resolver. It leaves out, and says so in `notes`, rpc or
document **encoded** operations, non-SOAP bindings and documents with several body parts. It refuses WSDL 2.0, `xs:redefine` and
what it can't resolve. Declared faults become types; decode `fault.detail` with their `...Read`.

Reading is lenient where servers are: unknown elements are ignored, order isn't checked, and an element is found by namespace and
then by local name. It is strict on values: what doesn't parse is a problem in `call.decoding`, `ok()` is false and `call.problem()`
says where.

### Why a tool

The tool is the default: it writes a client you commit and read, and a build needs neither the WSDL nor a grant. Generating at
compile time works too, since ablac 0.2.32: `#wsdlGenerateFrom(...)` gives the same bytes as the tool with only `filesystem.read`
granted, also in a program that imports WS-Security (whose AES brings `abla/simd`). The project authorizes it in its `abla.toml`
(`compileCapabilities = ["filesystem.read"]`) and the module asks for it:

```abla
import github("AndreBaltazar8/abla-soap/generate")
import "abla/compiler"
import "abla/fs"

#compilerGrant("filesystem.read")

compile fun shopClient(): string =
    wsdlGenerateFrom(path("shop.wsdl").readText(), WsdlGenerateOptions(prefix = "Shop")).source
```

`.source` is the client's source, as the tool would write it. The WSDL must then be there at every build.
`tests/compile-time/` checks that it matches the tool's output byte for byte. On ablac 0.2.31 and older such a `#` is denied
`trusted.native`.

## By hand

```abla
var out = soapWriter(soap12)
out.startBody()
out.xml.startElement("m:Ping")
out.xml.namespace("m", "urn:m")
out.xml.endElement()
val written = out.finish()

val parsed = soapParse(responseBytes)
val envelope = parsed.envelope
if (envelope != null) {
    val fault = envelope.fault
    if (fault != null) println("${fault.code.local}: ${fault.message}")
}
```

The same calls always give the same bytes, as abla-xml's writer does. `soapClient(http, path, version, headers, secure)` takes any
`HttpClient`, and `begin`, `body` and `send` are what generated code calls:

```abla
var message = client.begin()
message.body()
message.writer.xml.element("ping", "hello")
val response = client.send("urn:ping", message)
```

### Faults

A fault is the answer whatever the HTTP status. `SoapFault` has `code` (`local`, `namespace` from where its prefix was declared,
`text` as written), `subcodes`, `message`, `reasons`, `role`, `node`, `detail`, `isFrom(local, namespace)` and `blamesSender()`
for 1.1's Client and 1.2's Sender.

Anything else that isn't 2xx, or an envelope in the other version, or a mandatory header not named in `understood`, is an `error`
with a `code`. An empty 2xx is a call with nothing to return.

## WS-Security

`SoapHeaderSource`s are written afresh for each call, and refuse to go over a connection not marked `secure`.

- `WsseUsernameToken(username, password, digest = true)`: the OASIS 2004 profile, with `PasswordDigest` or `PasswordText`.
- `atUsernameToken(username, password, publicKeyPem)`: AT's profile, from its *Manual de Integração de Software, Comunicação por
  webservice, Aspetos genéricos*, 2.2.1. For each request a new AES-128 key, RSA-encrypted under AT's public key with PKCS#1 v1.5 as
  `Nonce`, encrypting `Password` and `Created` in ECB with PKCS#5 padding, all in Base64, in the `2002/12/secext` namespace. Those
  primitives are AT's choice, and these are the only places they are used.

Keys given as Abla strings can't be wiped; see `abla/crypto`'s notes.

## Hostile input

Responses and WSDLs go through a parser with limits. `SoapParseOptions` has 16 MiB, depth 128, a million nodes; `WsdlOptions` has
8 MiB, depth 128, a million nodes and 32 documents. A DOCTYPE is always refused, which takes external entities, external subsets
and entity expansion with it. Processing instructions in a SOAP message are refused, as the specification says. Imports are read
only through a resolver you pass, and `tools/wsdl2abla` reads only relative paths under `--imports`.

What a WSDL names reaches generated source only as escaped string literals and sanitized identifiers;
`tests/fixtures/hostile-names.wsdl` is generated and compiled to hold that.

## Tests

| | What it does |
|---|---|
| `make test` | envelopes, faults, the security profiles, hostile XML, the WSDL model, a generated client byte for byte |
| `make at` | clients generated from AT's four published WSDLs (and VIES's), fetched by hash and not committed, against `tests/at/stand_in.ab`: mutual TLS, certificates refused, and the token opened by `openssl`, not by this library. A `.pfx` as well as PEM. Also that a program without `tls` has no OpenSSL, and the package subpaths. Never calls AT |

The `testing-at` subpath exposes `atStandInMain()` for downstream integration suites. Its program takes `FOLDER PORT [soap]`, writes `port`, `ready` and redacted `log.jsonl` in the certificate folder, and binds only IPv6 loopback. `PORT=0` chooses a free port. The optional `soap` mode keeps this library's strict client fixture; the default models registration, consultation, finalization, annulment and transport, including refusals, a timeout and a lost reply. It needs `openssl` and `date` on PATH and never calls AT.

The same fixture supports the qualified `InvoicesRequest` at `/fatshare/ws/fatshareFaturas` (the separate query WSDL, not invoice submission). `FOLDER/efatura.json` may contain an `invoices` array, with `buyerTaxId`, `supplierTaxId`, `number`, `atcud`, `date`, optional `kind` (FT by default), and decimal strings `net`, `tax`, `total`. It filters by taxpayer/date and pages as the WSDL specifies; empty results omit `InvoicesList`. The manual 2.1.10 validation codes and namespace/choice rules are enforced. Optional fixture modes `dropOnce`, `delayOnce`, `refuse` (with `code`, `message`), `fault` (with `message`), `badPage` and `changedTotal` exercise callers; `onPage` scopes a mode to one page. `minYear` can model an unavailable year. The original strict and stateful series/transport modes are unchanged.

Nothing here has been run against AT's real services: that needs AT's test credentials, and is the first thing to do with them.

## Limits

No WS-Addressing, XML signatures, MTOM or attachments. HTTP is one request per connection, with the response in memory up to
`maximumResponseBytes` (16 MiB by `SoapTlsOptions`). Client-side use only: `soapWriteFault` is there for servers and tests, and
there's no server. x86-64 Linux has a random source by default; elsewhere call `cryptoSetRandom`, or RSA and the nonce say so.

## License

MPL-2.0.
