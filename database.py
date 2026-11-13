
import os
from pathlib import Path

import pyodbc
from dotenv import load_dotenv

# Cargar el archivo .env del proyecto
BASE_DIR = Path(__file__).resolve().parent
ENV_PATH = BASE_DIR / ".env"
load_dotenv(dotenv_path=ENV_PATH, override=True)

# Configuración de SQL Server
DB_SERVER = os.getenv("DB_SERVER", r"DESKTOP-G9RDFOS\SQLDEV")
DB_NAME = os.getenv("DB_NAME", "DB_MonitoreoAire")
DB_DRIVER = os.getenv(
    "DB_DRIVER",
    "ODBC Driver 18 for SQL Server"
)

# Normalizar el valor del certificado
trust_cert = os.getenv(
    "DB_TRUST_SERVER_CERTIFICATE",
    "yes"
).strip().lower()

if trust_cert in ("yes", "true", "1"):
    trust_cert = "yes"
else:
    trust_cert = "no"


def get_connection():
    """Conectar usando autenticación de Windows."""

    if not DB_SERVER or not DB_NAME:
        raise RuntimeError(
            f"Falta configuración de SQL Server en {ENV_PATH}"
        )

    connection_string = (
        f"DRIVER={{{DB_DRIVER}}};"
        f"SERVER={DB_SERVER};"
        f"DATABASE={DB_NAME};"
        "Trusted_Connection=yes;"
        "Encrypt=yes;"
        f"TrustServerCertificate={trust_cert};"
        "Connection Timeout=10;"
    )

    return pyodbc.connect(connection_string)


def test_connection():
    """Probar la conexión con SQL Server."""

    connection = None

    try:
        connection = get_connection()
        cursor = connection.cursor()

        cursor.execute("""
            SELECT
                @@SERVERNAME,
                DB_NAME(),
                ORIGINAL_LOGIN()
        """)

        row = cursor.fetchone()

        return {
            "ok": True,
            "servidor": row[0],
            "base_datos": row[1],
            "usuario_windows": row[2]
        }

    except Exception as error:
        return {
            "ok": False,
            "error": str(error)
        }

    finally:
        if connection is not None:
            connection.close()