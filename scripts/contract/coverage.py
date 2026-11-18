"""Cobertura de la corrida de contrato, sacada del reporte HAR de Schemathesis.

Uso: python scripts/contract/coverage.py openapi.yaml contract-report/har-*.json

Cuenta, por operacion del contrato, los status que devolvio el servicio. "Tocadas" son las que
recibieron al menos un pedido; "con 2xx" son las que obtuvieron al menos una respuesta de camino
feliz. Sale con 1 si una operacion no obtuvo ningun 2xx y no esta en EXPECTED_NO_2XX.
"""

import glob
import json
import re
import sys
from collections import defaultdict
from urllib.parse import unquote, urlsplit

import yaml

# Operaciones que en esta prueba no pueden dar 2xx, con el motivo.
EXPECTED_NO_2XX = {
    # Guardar el archivo necesita Cloudinary o Supabase, que la prueba nunca usa (son servicios
    # reales): lo mas lejos que llega es 503, que el contrato declara.
    ("POST", "/v1/attachments"),
    # Ademas del almacenamiento, exige un ticket de un solo uso en X-Upload-Ticket, y el ticket
    # lo emite POST /v1/attachment-tickets: Schemathesis no encadena una operacion con la otra.
    ("POST", "/v1/attachments/direct"),
    # Da 200 solo si el destinatario es un usuario conocido y no hay bloqueos entre ambos; con los
    # ids que genera Schemathesis (uuids al azar) lo mas lejos que llega es el 403, que el contrato
    # declara. Sembrar un par de usuarios para esto queda fuera de la prueba de contrato.
    ("GET", "/v1/voice-access/{recipient_id}"),
}

HTTP_METHODS = {"get", "put", "post", "delete", "patch", "head", "options"}


def load_operations(path):
    with open(path, encoding="utf-8") as handle:
        spec = yaml.safe_load(handle)
    operations = []
    for template, item in spec["paths"].items():
        pattern = re.compile("^" + re.sub(r"\{[^}]+\}", "[^/]+", re.escape(template).replace(r"\{", "{").replace(r"\}", "}")) + "$")
        for method in item:
            if method in HTTP_METHODS:
                operations.append((method.upper(), template, pattern))
    return operations


def main():
    spec_path = sys.argv[1]
    har_files = [name for arg in sys.argv[2:] for name in glob.glob(arg)]
    operations = load_operations(spec_path)
    seen = defaultdict(lambda: defaultdict(int))
    for har_path in har_files:
        with open(har_path, encoding="utf-8") as handle:
            entries = json.load(handle)["log"]["entries"]
        for entry in entries:
            method = entry["request"]["method"]
            path = unquote(urlsplit(entry["request"]["url"]).path)
            status = entry["response"]["status"]
            for op_method, template, pattern in operations:
                if op_method == method and pattern.match(path):
                    seen[(op_method, template)][status] += 1
                    break

    touched = [op for op in operations if seen[(op[0], op[1])]]
    happy = [op for op in operations if any(200 <= s < 300 for s in seen[(op[0], op[1])])]
    missing = [op for op in operations if op not in happy and (op[0], op[1]) not in EXPECTED_NO_2XX]
    print(f"Operaciones tocadas: {len(touched)} de {len(operations)}")
    print(f"Operaciones con al menos un 2xx real: {len(happy)} de {len(operations)}")
    for method, template, _ in operations:
        statuses = seen[(method, template)]
        summary = ", ".join(f"{status}x{count}" for status, count in sorted(statuses.items()))
        mark = "2xx" if any(200 <= s < 300 for s in statuses) else "---"
        print(f"  [{mark}] {method} {template}: {summary or 'sin pedidos'}")

    if missing:
        names = ", ".join(f"{m} {t}" for m, t, _ in missing)
        print(f"ERROR: sin ningun 2xx y sin justificar en EXPECTED_NO_2XX: {names}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
