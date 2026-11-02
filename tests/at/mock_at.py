"""A local stand-in for AT's web services: mutual TLS, and the token opened with openssl, by nothing of abla-soap's.

Takes the directory of test certificates and a file to write its port to. Stops when asked at /stop.
"""
import base64
import datetime
import http.server
import pathlib
import socket
import ssl
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

directory = pathlib.Path(sys.argv[1])
SECEXT = "{http://schemas.xmlsoap.org/ws/2002/12/secext}"
SOAP = "{http://schemas.xmlsoap.org/soap/envelope/}"
ENVELOPE = '<S:Envelope xmlns:S="http://schemas.xmlsoap.org/soap/envelope/"><S:Body>%s</S:Body></S:Envelope>'


def fault(code, message):
    return ENVELOPE % f"<S:Fault><faultcode>S:{code}</faultcode><faultstring>{message}</faultstring></S:Fault>"


def open_token(token):
    """What the token holds: the key under RSA, and the password and time under the key."""
    nonce = base64.b64decode(token.find(SECEXT + "Nonce").text)
    with tempfile.NamedTemporaryFile() as held:
        held.write(nonce)
        held.flush()
        key = subprocess.run(
            ["openssl", "pkeyutl", "-decrypt", "-inkey", str(directory / "at.key"), "-in", held.name,
             "-pkeyopt", "rsa_padding_mode:pkcs1"],
            check=True, capture_output=True).stdout
    assert len(key) == 16, "the request's key is 128 bits"

    def aes(field):
        return subprocess.run(
            ["openssl", "enc", "-d", "-aes-128-ecb", "-K", key.hex()],
            input=base64.b64decode(token.find(SECEXT + field).text),
            check=True, capture_output=True).stdout.decode()

    return aes("Password"), aes("Created")


def answer(body):
    root = ET.fromstring(body)
    header = root.find(SOAP + "Header")
    token = header.find(SECEXT + "Security").find(SECEXT + "UsernameToken")
    if [child.tag for child in token] != [SECEXT + n for n in ("Username", "Password", "Nonce", "Created")]:
        return 500, fault("Client", "the token isn't in the manual's order")
    password, created = open_token(token)
    if token.find(SECEXT + "Username").text != "599999993/37" or password != "testes1234":
        return 500, fault("Client", "Authentication failed")
    moment = datetime.datetime.fromisoformat(created.replace("Z", "+00:00"))
    if abs((datetime.datetime.now(datetime.timezone.utc) - moment).total_seconds()) > 300:
        return 500, fault("Client", "Created is out of time")
    request = root.find(SOAP + "Body")[0]
    name = request.tag
    if name == "{http://at.gov.pt/}registarSerie":
        if request.find("serie") is None or request.find("numCertSWFatur").text != "9999":
            return 500, fault("Client", "unqualified children, as the schema says")
        if request.find("tipoDoc").text == "XX":
            return 200, ENVELOPE % ('<ns2:registarSerieResponse xmlns:ns2="http://at.gov.pt/"><registarSerieResp>'
                                    "<infoResultOper><codResultOper>4046</codResultOper>"
                                    "<msgResultOper>Tipo inv&#225;lido</msgResultOper></infoResultOper>"
                                    "</registarSerieResp></ns2:registarSerieResponse>")
        info = ("<infoSerie><serie>A</serie><tipoSerie>N</tipoSerie><classeDoc>SI</classeDoc><tipoDoc>FT</tipoDoc>"
                "<numInicialSeq>1</numInicialSeq><dataInicioPrevUtiliz>2026-11-02</dataInicioPrevUtiliz>"
                "<meioProcessamento>PI</meioProcessamento><numCertSWFatur>9999</numCertSWFatur>"
                "<codValidacaoSerie>AAJFJ3K5</codValidacaoSerie><dataRegisto>2026-11-02</dataRegisto>"
                "<estado>A</estado><dataEstado>2026-11-02T10:00:00</dataEstado><nifComunicou>599999993</nifComunicou>"
                "</infoSerie>")
        return 200, ENVELOPE % ('<ns2:registarSerieResponse xmlns:ns2="http://at.gov.pt/"><registarSerieResp>'
                                f"{info}<infoResultOper><codResultOper>2001</codResultOper>"
                                "<msgResultOper>Registada</msgResultOper></infoResultOper>"
                                "</registarSerieResp></ns2:registarSerieResponse>")
    if name == "{https://servicos.portaldasfinancas.gov.pt/sgdtws/documentosTransporte/}envioDocumentoTransporteRequestElem":
        if request.find("DocumentNumber").text != "GT A/1":
            return 500, fault("Client", "the document number")
        return 200, ENVELOPE % ('<n:envioDocumentoTransporteResponseElem xmlns:n="https://servicos.portaldasfinancas.gov.pt/sgdtws/documentosTransporte/">'
                                "<ResponseStatus><ReturnCode>0</ReturnCode><ReturnMessage>OK</ReturnMessage></ResponseStatus>"
                                "<DocumentNumber>GT A/1</DocumentNumber><ATDocCodeID>123</ATDocCodeID>"
                                "</n:envioDocumentoTransporteResponseElem>")
    return 500, fault("Client", f"what's {name}?")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *arguments):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.path == "/stop":
            status, text = 200, ""
        elif "text/xml" not in self.headers["Content-Type"] or "SOAPAction" not in self.headers:
            status, text = 400, fault("Client", "SOAP 1.1's headers are missing")
        elif self.connection.getpeercert()["subject"][0][0][1] != "abla-soap-client":
            status, text = 403, fault("Client", "whose certificate is this?")
        else:
            try:
                status, text = answer(body)
            except Exception as problem:
                status, text = 500, fault("Server", f"the token doesn't open: {type(problem).__name__}")
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True
        if self.path == "/stop":
            self.server.stopping = True


# abla/tls/hosted takes localhost to mean ::1.
class Server(http.server.HTTPServer):
    address_family = socket.AF_INET6


server = Server(("::1", 0), Handler)
server.stopping = False
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(directory / "server.crt", directory / "server.key")
context.load_verify_locations(directory / "ca.crt")
context.verify_mode = ssl.CERT_REQUIRED
server.socket = context.wrap_socket(server.socket, server_side=True)
pathlib.Path(sys.argv[2]).write_text(str(server.server_address[1]))
while not server.stopping:
    try:
        server.handle_request()
    except (ssl.SSLError, OSError):
        pass
