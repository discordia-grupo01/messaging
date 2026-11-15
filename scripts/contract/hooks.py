"""Hooks de Schemathesis para la prueba de contrato de messaging.

El archivo schemathesis.toml solo sabe fijar parametros de path, query y header; el usuario a
bloquear va en el cuerpo, asi que se fija aca. Se carga con SCHEMATHESIS_HOOKS=hooks y
PYTHONPATH=scripts/contract (lo hace scripts/contract-test.sh).
"""

import schemathesis

# Usuario que scripts/contract/seed.exs deja registrado y que no es quien hace el pedido.
KNOWN_OTHER_USER = "00000000-0000-4000-8000-0000000000e2"


@schemathesis.hook
def map_body(context, body):
    operation = context.operation
    if operation.method.upper() == "POST" and operation.path == "/v1/blocks":
        # Solo se toca un cuerpo bien formado: los casos con un tipo equivocado siguen intactos.
        if isinstance(body, dict) and isinstance(body.get("user_id"), str):
            return {**body, "user_id": KNOWN_OTHER_USER}
    return body


def _is_search(context):
    operation = context.operation
    return operation.method.upper() == "GET" and operation.path == "/v1/servers/{server_id}/messages/search"


# El servidor sembrado y un texto que existe: con un id inventado la busqueda siempre es 403 y sin
# q ni author_id siempre es 400. El config de schemathesis no logra fijar estos dos.
SEEDED_SERVER = "00000000-0000-4000-8000-0000000000a1"


@schemathesis.hook
def map_path_parameters(context, path_parameters):
    if _is_search(context) and isinstance(path_parameters, dict):
        return {**path_parameters, "server_id": SEEDED_SERVER}
    return path_parameters


@schemathesis.hook
def map_query(context, query):
    if _is_search(context) and isinstance(query, dict) and isinstance(query.get("q"), str):
        # Los demas parametros generados (limit, before, author_id, channel_id) casi siempre rompen
        # alguna regla que el contrato no expresa (400); se dejan afuera para llegar al 200.
        return {"q": "hola"}
    return query
