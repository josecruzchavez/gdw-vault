#!/usr/bin/env python3
"""
Smoke test E2E del servidor MCP de GDW Vault.

Ejecuta el binario real (`gdw-vault --mcp`), habla JSON-RPC por stdio y
valida las herramientas del vault. Crea sus propias conexiones de prueba
(sin password: no toca el Keychain), las limpia al final y no depende de
los datos reales del usuario.

Sin Touch ID por defecto: solo rutas que no requieren autorización.
Con --interactive añade las pruebas que piden huella (skip si la conexión
real que usan no está disponible).

Uso:
    python3 tests/smoke_test.py                # modo desatendido
    python3 tests/smoke_test.py --interactive  # incluye pruebas con Touch ID
"""
import argparse
import json
import os
import sqlite3
import subprocess
import sys
import time

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.environ.get("GDW_VAULT_BIN") or os.path.join(PROJECT_DIR, "gdw-vault")
DB = os.path.expanduser("~/Library/Application Support/GDWVault/vault.db")

EXPECTED_TOOLS = [
    "list_groups", "list_connections", "get_connection",
    "get_connection_password", "create_connection", "update_connection",
    "delete_connection", "list_keys", "db_query", "ssh_exec",
    "get_connection_command", "run_with_secret", "http_request",
]

SMOKE_GROUP = "GDW-Smoke"
SMOKE_DB = "Smoke Test Conn"        # mysql, 127.0.0.1 (sin password)
SMOKE_SSH = "Smoke SSH"             # sftp, 1.2.3.4 (sin password)
SMOKE_API = "Smoke API"             # api, URL ficticia (sin token)
SMOKE_REAL = "Localhost"            # conexión real opcional para interactivas


class McpClient:
    """Cliente JSON-RPC por stdio contra el binario real."""

    def __init__(self):
        self.proc = subprocess.Popen(
            [APP, "--mcp"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True)
        self.next_id = 1

    def send(self, payload):
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()

    def recv(self, want_id, timeout=30):
        deadline = time.time() + timeout
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                return None
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue
            if data.get("id") == want_id:
                return data
        return None

    def initialize(self):
        self.send({"jsonrpc": "2.0", "id": self.next_id, "method":
                   "initialize", "params": {"protocolVersion": "2024-11-05"}})
        resp = self.recv(self.next_id)
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return resp

    def call(self, tool, args, timeout=30):
        rid = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                   "params": {"name": tool, "arguments": args}})
        resp = self.recv(rid, timeout)
        if resp is None:
            return None
        try:
            return json.loads(resp["result"]["content"][0]["text"])
        except (KeyError, json.JSONDecodeError):
            return {"_raw": str(resp)}

    def raw(self, method, timeout=10):
        rid = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": rid, "method": method})
        return self.recv(rid, timeout)

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.kill()
        except Exception:
            pass


def cleanup_smoke_rows():
    """Borra las conexiones de prueba directo de la BD (sin Touch ID)."""
    try:
        con = sqlite3.connect(DB)
        con.execute("DELETE FROM connections WHERE name IN (?, ?, ?, ?)",
                    (SMOKE_DB, SMOKE_DB + " 2", SMOKE_SSH, SMOKE_API))
        con.execute("DELETE FROM groups WHERE name = ?", (SMOKE_GROUP,))
        con.commit()
        con.close()
    except Exception as exc:
        print(f"  (aviso: limpieza falló: {exc})")


class Suite:
    def __init__(self, client):
        self.client = client
        self.passed = []
        self.failed = []
        self.skipped = []

    def check(self, name, condition, detail=""):
        if condition:
            self.passed.append(name)
            print(f"  ✓ {name}")
        else:
            self.failed.append((name, detail))
            print(f"  ✕ {name} — {detail}")

    def skip(self, name, reason):
        self.skipped.append(name)
        print(f"  ⊘ {name} — omitido: {reason}")

    def tool_result(self, tool, args, timeout=30):
        resp = self.client.call(tool, args, timeout)
        if resp is None:
            return {"ok": False, "output": "(sin respuesta)"}
        return resp

    def connection_exists(self, name):
        r = self.tool_result("list_connections", {})
        return any(x.get("name") == name for x in r.get("connections", []))


def run_unattended(s):
    c = s.client

    # 1. initialize
    resp = c.initialize()
    info = (resp or {}).get("result", {}).get("serverInfo", {})
    s.check("initialize: serverInfo gdw-vault-native",
            info.get("name") == "gdw-vault-native", str(info))

    # 2. tools/list
    resp = c.raw("tools/list")
    tools = [t["name"] for t in (resp or {}).get("result", {}).get("tools", [])]
    missing = [t for t in EXPECTED_TOOLS if t not in tools]
    s.check(f"tools/list: {len(EXPECTED_TOOLS)} herramientas presentes", not missing,
            f"faltan: {missing}")

    # 3. list_groups
    r = s.tool_result("list_groups", {})
    s.check("list_groups: devuelve lista", isinstance(r.get("groups"), list),
            str(r)[:120])

    # 4. crear conexiones de prueba (sin password: no toca el Keychain)
    r = s.tool_result("create_connection", {
        "group_name": SMOKE_GROUP, "name": SMOKE_DB, "protocol": "mysql",
        "host": "127.0.0.1", "port": 3306, "username": "smoke_user",
        "database": "smoke_db"})
    s.check("create_connection mysql: crea y devuelve id",
            r.get("ok") is True and isinstance(r.get("id"), int), str(r)[:120])

    r = s.tool_result("create_connection", {
        "group_name": SMOKE_GROUP, "name": SMOKE_SSH, "protocol": "sftp",
        "host": "1.2.3.4", "port": 22, "username": "smoke_ssh"})
    s.check("create_connection sftp: crea y devuelve id",
            r.get("ok") is True and isinstance(r.get("id"), int), str(r)[:120])

    # 5. list_connections contiene las de prueba
    r = s.tool_result("list_connections", {})
    names = [x.get("name") for x in r.get("connections", [])]
    s.check("list_connections: contiene las de prueba",
            SMOKE_DB in names and SMOKE_SSH in names, str(names)[:120])

    # 6. get_connection por nombre parcial
    r = s.tool_result("get_connection", {"name": "smoke t"})
    s.check("get_connection: parcial 'smoke t' → Smoke Test Conn",
            r.get("name") == SMOKE_DB and bool(r.get("host")), str(r)[:120])

    # 7. update_connection
    r = s.tool_result("update_connection", {
        "name": SMOKE_DB, "new_name": SMOKE_DB + " 2", "notes": "editada"})
    s.check("update_connection: renombra", r.get("ok") is True, str(r)[:120])

    # 8. get_connection del renombrado (parcial)
    r = s.tool_result("get_connection", {"name": "smoke test"})
    s.check("get_connection: encuentra el renombrado",
            r.get("name") == SMOKE_DB + " 2", str(r)[:120])

    # 9. db_query bloqueada en modo lectura (sin Touch ID ni Keychain)
    r = s.tool_result("db_query", {
        "db_name": "smoke test", "database": "smoke_db",
        "sql": "DELETE FROM inventario WHERE id=999;"})
    s.check("db_query: DELETE bloqueado en modo lectura",
            r.get("ok") is False and "Modo 'lectura'" in r.get("output", ""),
            str(r)[:150])

    # 10. db_query con conexión inexistente
    r = s.tool_result("db_query", {"db_name": "no-existe-xyz",
                                   "sql": "SELECT 1;"})
    s.check("db_query: conexión inexistente reportada",
            r.get("ok") is False and "No existe" in r.get("output", ""),
            str(r)[:150])

    # 11. ssh_exec destructivo bloqueado en modo lectura
    r = s.tool_result("ssh_exec", {
        "ssh_name": "smoke ssh", "command": "rm -rf /tmp/gdw_smoke"})
    s.check("ssh_exec: rm bloqueado en modo lectura",
            r.get("ok") is False and "Modo 'lectura'" in r.get("output", ""),
            str(r)[:150])

    # 12. ssh_exec con conexión inexistente
    r = s.tool_result("ssh_exec", {"ssh_name": "zzz-no-existe",
                                   "command": "ls"})
    s.check("ssh_exec: conexión inexistente reportada",
            r.get("ok") is False and "No existe" in r.get("output", ""),
            str(r)[:150])

    # 13. get_connection_command mysql (sin db guardada: termina en -p)
    r = s.tool_result("get_connection_command", {"name": "smoke test"})
    cmd = r.get("command", "")
    s.check("get_connection_command: mysql correcto",
            cmd.startswith("mysql -h 127.0.0.1") and "-u smoke_user" in cmd
            and ("-p smoke_db" in cmd or cmd.rstrip().endswith("-p")), cmd)
    s.check("get_connection_command: sugiere portapapeles",
            "portapapeles" in r.get("sugerencia", ""), str(r)[:150])

    # 14. get_connection_command ssh
    r = s.tool_result("get_connection_command", {"name": "smoke ssh"})
    s.check("get_connection_command: ssh correcto",
            (r.get("command") or "").startswith("ssh smoke_ssh@1.2.3.4"),
            str(r.get("command"))[:120])

    # 15. tool desconocida
    r = s.tool_result("no_existe", {})
    s.check("tool desconocida: error claro",
            r.get("ok") is False and "Tool desconocida" in r.get("error", ""),
            str(r)[:150])

    # 16. método JSON-RPC inválido
    resp = c.raw("resources/list")
    err = (resp or {}).get("error", {})
    s.check("método inválido: -32601",
            err.get("code") == -32601, str(err)[:120])

    # 17. run_with_secret: destructivo bloqueado en modo lectura
    r = s.tool_result("run_with_secret", {
        "name": "smoke ssh", "command": "rm -rf /tmp/gdw_smoke"})
    s.check("run_with_secret: rm bloqueado en modo lectura",
            r.get("ok") is False and "Modo 'lectura'" in r.get("output", ""),
            str(r)[:150])

    # 18. run_with_secret: sin secreto ni llave → error claro
    r = s.tool_result("run_with_secret", {
        "name": "smoke ssh", "command": "ls /tmp"})
    s.check("run_with_secret: sin secreto reportado",
            r.get("ok") is False and "no tiene password ni llave" in r.get("output", ""),
            str(r)[:150])

    # 19. create_connection api con autenticación por token
    r = s.tool_result("create_connection", {
        "group_name": SMOKE_GROUP, "name": SMOKE_API, "protocol": "api",
        "url": "https://smoke.example/api", "auth_type": "header",
        "header_name": "X-API-Key"})
    s.check("create_connection api: auth_type aceptado",
            r.get("ok") is True, str(r)[:150])

    # 20. auth_type inválido rechazado
    r = s.tool_result("create_connection", {
        "group_name": SMOKE_GROUP, "name": SMOKE_API + " bad", "protocol": "api",
        "url": "https://smoke.example/api", "auth_type": "oauth2"})
    s.check("create_connection api: auth_type inválido rechazado",
            r.get("ok") is False and "auth_type" in r.get("error", ""),
            str(r)[:150])

    # 21. get_connection expone url + auth HTTP en details
    r = s.tool_result("get_connection", {"name": "smoke api"})
    s.check("get_connection api: details con url y auth",
            "smoke.example" in str(r.get("details", ""))
            and "X-API-Key" in str(r.get("details", "")), str(r)[:150])

    # 22. http_request sin token guardado → error claro (no intenta red)
    r = s.tool_result("http_request", {"name": "smoke api", "path": "/ping"})
    s.check("http_request: falta de token reportada",
            r.get("ok") is False and "token" in r.get("error", ""),
            str(r)[:150])


def run_interactive(s):
    """Pruebas que requieren Touch ID (aprobar cuando salga el diálogo)."""
    # A. get_connection_password (usa la conexión real si existe)
    if s.connection_exists(SMOKE_REAL):
        r = s.tool_result("get_connection_password",
                          {"name": SMOKE_REAL}, 90)
        if r.get("ok") and r.get("secret"):
            s.check("get_connection_password: entrega secreto con huella", True)
        elif "password guardado" in r.get("error", ""):
            s.skip("get_connection_password", f"{SMOKE_REAL} no tiene password")
        else:
            s.check("get_connection_password: entrega secreto con huella",
                    False, str(r)[:120])
    else:
        s.skip("get_connection_password", f"{SMOKE_REAL} no existe")

    # B. db_query de lectura real (túnel o directo)
    if s.connection_exists(SMOKE_REAL):
        r = s.tool_result("db_query", {
            "db_name": SMOKE_REAL,
            "sql": "SELECT COUNT(*) AS tablas FROM information_schema.tables "
                   "WHERE table_schema=database();"}, 90)
        if r.get("ok") and "tablas" in r.get("output", ""):
            s.check("db_query: SELECT real ejecutado", True)
        elif "password guardado" in r.get("output", ""):
            s.skip("db_query", f"{SMOKE_REAL} no tiene password")
        else:
            s.check("db_query: SELECT real ejecutado", False, str(r)[:150])
    else:
        s.skip("db_query", f"{SMOKE_REAL} no existe")

    # C. ssh_exec de lectura real (primera ssh/sftp con password)
    r = s.tool_result("list_connections", {})
    ssh_conn = next((x for x in r.get("connections", [])
                     if x.get("protocol") in ("ssh", "sftp")), None)
    if ssh_conn:
        name = ssh_conn["name"]
        r = s.tool_result("ssh_exec", {"ssh_name": name,
                                       "command": "hostname"}, 90)
        if r.get("ok"):
            s.check("ssh_exec: hostname real", True)
        elif "password guardado" in r.get("output", ""):
            s.skip("ssh_exec", f"{name} no tiene password guardado")
        else:
            s.check("ssh_exec: hostname real", False, str(r)[:150])
    else:
        s.skip("ssh_exec", "no hay conexiones ssh/sftp")

    # D. get_connection_command con password al portapapeles
    if s.connection_exists(SMOKE_REAL):
        r = s.tool_result("get_connection_command",
                          {"name": SMOKE_REAL, "copy_password": True}, 90)
        if "copiado al portapapeles" in r.get("sugerencia", ""):
            s.check("get_connection_command: password al portapapeles", True)
        elif "password guardado" in r.get("sugerencia", "") + r.get("error", ""):
            s.skip("get_connection_command", "sin password en la conexión")
        else:
            s.check("get_connection_command: password al portapapeles",
                    False, str(r)[:150])
    else:
        s.skip("get_connection_command", f"{SMOKE_REAL} no existe")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--interactive", action="store_true",
                        help="incluir pruebas que piden Touch ID")
    args = parser.parse_args()

    if not os.path.exists(APP):
        print(f"✕ No existe {APP} — compila e instala primero")
        sys.exit(1)

    cleanup_smoke_rows()
    client = McpClient()
    suite = Suite(client)
    print(f"Smoke test E2E — {APP}")
    print("== Desatendidas ==")
    try:
        run_unattended(suite)
        if args.interactive:
            print("== Interactivas (Touch ID) ==")
            run_interactive(suite)
    finally:
        client.close()
        cleanup_smoke_rows()

    total = len(suite.passed) + len(suite.failed)
    print(f"\nResultado: {len(suite.passed)}/{total} pasaron, "
          f"{len(suite.skipped)} omitidas")
    if suite.failed:
        print("Fallidas:")
        for name, detail in suite.failed:
            print(f"  - {name}: {detail}")
        sys.exit(1)
    print("✓ Todo en orden")


if __name__ == "__main__":
    main()
