import os
from datetime import datetime
from decimal import Decimal, InvalidOperation

from flask import Flask, request, jsonify, render_template
from dotenv import load_dotenv

from database import get_connection, BASE_DIR

# ==========================================
# CONFIGURACIÓN
# ==========================================

load_dotenv(BASE_DIR / ".env", override=True)

app = Flask(__name__)

API_KEY = os.getenv("API_KEY", "")

# El ESP32 envía cada 30 s. Pasado este tiempo la lectura se considera sin señal.
SEGUNDOS_MAXIMOS_SIN_DATOS = 120

# Lecturas ADC fuera de este rango indican sensor desconectado o saturado.
ADC_MINIMO = 20
ADC_MAXIMO = 4075

MENSAJES = {
    "Bueno": "El aire está en buenas condiciones. No se requiere ninguna acción.",
    "Medio": "Calidad moderada. Las personas sensibles deberían reducir el "
             "tiempo en este lugar. Conviene ventilar.",
    "Malo": "Calidad mala. Se recomienda ventilar el espacio o salir del "
            "lugar si es posible.",
}


# ==========================================
# UTILIDADES
# ==========================================

def validar_api_key():
    """Validar la clave enviada en X-API-Key."""
    if not API_KEY:
        return False
    return request.headers.get("X-API-Key", "") == API_KEY


def nivel_de_puntaje(puntaje):
    if puntaje is None:
        return None
    if puntaje >= 66:
        return "Malo"
    if puntaje >= 33:
        return "Medio"
    return "Bueno"


def num(valor, decimales=4):
    return None if valor is None else round(float(valor), decimales)


def fecha_texto(fecha):
    return fecha.strftime("%Y-%m-%d %H:%M:%S") if fecha else None


def validar_lectura(fecha, adc, tiene_calidad):
    """Comprobar si la última lectura es confiable. Devuelve (valida, motivo)."""
    if fecha is None:
        return False, "Todavía no hay lecturas"

    edad = (datetime.now() - fecha).total_seconds()

    if edad > SEGUNDOS_MAXIMOS_SIN_DATOS:
        if edad < 3600:
            hace = f"{int(edad // 60)} min"
        elif edad < 86400:
            hace = f"{int(edad // 3600)} h"
        else:
            hace = f"{int(edad // 86400)} días"
        return False, f"Sin señal: la última lectura llegó hace {hace}"

    if adc is None or adc < ADC_MINIMO or adc > ADC_MAXIMO:
        return False, "Valor fuera de rango: revisa el cableado del sensor"

    if not tiene_calidad:
        return False, "No se pudo calcular la calidad (voltaje fuera de rango)"

    return True, "Lectura válida y reciente"


def consultar_estado(cursor, codigo_ubicacion=None):
    """Última lectura ADC (global o de una ubicación) con sus gases."""

    filtro = "AND U.Codigo_ubicacion = ?" if codigo_ubicacion else ""
    parametros = [codigo_ubicacion] if codigo_ubicacion else []

    cursor.execute(f"""
        SELECT TOP 1
            M.Id_medida, M.Fecha_registro, M.Valor_medido, M.Voltaje,
            S.Codigo_sensor, S.Es_simulado,
            U.Codigo_ubicacion, U.Nombre, U.Tipo_lugar,
            C.Ratio_Rs_R0, C.Puntaje_ICA, C.Nivel, GD.Nombre
        FROM dbo.FACT_Medidas M
        JOIN dbo.DIM_tipo_Medicion T
             ON T.Id_tipo_medicion = M.Id_tipo_medicion AND T.Codigo_tipo = 'ADC'
        JOIN dbo.DIM_Sensor S    ON S.Id_sensor = M.Id_sensor
        JOIN dbo.DIM_Ubicacion U ON U.Id_ubicacion = M.Id_ubicacion
        LEFT JOIN dbo.FACT_Calidad C ON C.Id_medida = M.Id_medida
        LEFT JOIN dbo.DIM_Gas GD     ON GD.Id_gas = C.Id_gas_dominante
        WHERE 1 = 1 {filtro}
        ORDER BY M.Fecha_registro DESC, M.Id_medida DESC
    """, *parametros)

    fila = cursor.fetchone()

    if fila is None:
        return None

    (id_medida, fecha, adc, voltaje, sensor, simulado, cod_ubic, ubic,
     tipo_lugar, ratio, puntaje, nivel, gas_dominante) = fila

    cursor.execute("""
        SELECT G.Codigo_gas, G.Nombre, G.Formula, G.Unidad,
               FG.Concentracion, FG.Puntaje,
               G.Umbral_medio, G.Umbral_malo, G.Origen_curva
        FROM dbo.FACT_Gases FG
        JOIN dbo.DIM_Gas G ON G.Id_gas = FG.Id_gas
        WHERE FG.Id_medida = ?
        ORDER BY G.Orden
    """, id_medida)

    gases = [{
        "codigo": g[0], "nombre": g[1], "formula": g[2], "unidad": g[3],
        "concentracion": num(g[4], 4), "puntaje": num(g[5], 1),
        "nivel": nivel_de_puntaje(float(g[5])),
        "umbral_medio": num(g[6]), "umbral_malo": num(g[7]),
        "origen": g[8],
    } for g in cursor.fetchall()]

    valida, motivo = validar_lectura(fecha, float(adc), nivel is not None)

    return {
        "fecha": fecha_texto(fecha),
        "adc": num(adc, 1),
        "voltaje": num(voltaje, 3),
        "sensor": sensor,
        "simulado": bool(simulado),
        "ubicacion": {"codigo": cod_ubic, "nombre": ubic, "tipo": tipo_lugar},
        "ratio": num(ratio, 3),
        "puntaje": num(puntaje, 1),
        "nivel": nivel,
        "gas_dominante": gas_dominante,
        "mensaje": MENSAJES.get(nivel, ""),
        "valida": valida,
        "motivo_validacion": motivo,
        "gases": gases,
    }


# ==========================================
# PÁGINA PRINCIPAL
# ==========================================

@app.route("/", methods=["GET"])
def inicio():
    return render_template("index.html")


# ==========================================
# ESTADO DE FLASK Y SQL SERVER
# ==========================================

@app.route("/api/health", methods=["GET"])
def health():
    try:
        conexion = get_connection()
        conexion.close()

        return jsonify({
            "ok": True,
            "estado": "activo",
            "mensaje": "Conexión con SQL Server exitosa",
            "proyecto": "Monitoreo de calidad del aire",
            "base_datos": "SQL Server local"
        }), 200

    except Exception as error:
        app.logger.exception("Error al conectar con SQL Server")
        return jsonify({"ok": False, "estado": "error", "error": str(error)}), 500


# ==========================================
# ESTADÍSTICAS Y ESTADO ACTUAL
# ==========================================

@app.route("/api/estadisticas", methods=["GET"])
def estadisticas():
    """Totales + última lectura validada. Parámetro opcional: ubicacion."""

    conexion = None

    try:
        conexion = get_connection()
        cursor = conexion.cursor()

        cursor.execute("SELECT COUNT(*) FROM dbo.FACT_Medidas")
        total = cursor.fetchone()[0] or 0

        estado = consultar_estado(cursor, request.args.get("ubicacion"))

        return jsonify({
            "ok": True,
            "total_lecturas": total,
            "ultima_lectura": estado["adc"] if estado else None,
            "ultima_fecha": estado["fecha"] if estado else None,
            "estado": estado,
        }), 200

    except Exception as error:
        app.logger.exception("Error al consultar estadísticas")
        return jsonify({"ok": False, "error": str(error)}), 500

    finally:
        if conexion is not None:
            conexion.close()


# ==========================================
# SERIE DE TIEMPO PARA LAS GRÁFICAS
# ==========================================

@app.route("/api/serie", methods=["GET"])
def serie():
    """Serie agregada de una ubicación. Parámetros: ubicacion, minutos."""

    codigo = request.args.get("ubicacion", "")
    minutos = request.args.get("minutos", default=60, type=int)
    minutos = max(10, min(minutos, 1440))

    # Hasta ~120 puntos por gráfica: se promedian lecturas en "cubetas".
    cubeta = max(1, minutos // 120)

    conexion = None

    try:
        conexion = get_connection()
        cursor = conexion.cursor()

        # cubeta es un entero ya validado, por eso puede ir directo en el SQL
        cursor.execute(f"""
            SELECT
                DATEADD(MINUTE, X.Cb * {int(cubeta)}, '20000101') AS Fecha,
                X.Codigo_gas,
                AVG(X.Concentracion) AS Concentracion,
                AVG(X.Puntaje_ICA)   AS Puntaje_ICA
            FROM (
                SELECT
                    DATEDIFF(MINUTE, '20000101', M.Fecha_registro) / {int(cubeta)} AS Cb,
                    G.Codigo_gas, FG.Concentracion, C.Puntaje_ICA
                FROM dbo.FACT_Medidas M
                JOIN dbo.DIM_Ubicacion U ON U.Id_ubicacion = M.Id_ubicacion
                JOIN dbo.FACT_Calidad C  ON C.Id_medida = M.Id_medida
                JOIN dbo.FACT_Gases FG   ON FG.Id_medida = M.Id_medida
                JOIN dbo.DIM_Gas G       ON G.Id_gas = FG.Id_gas
                WHERE U.Codigo_ubicacion = ?
                  AND M.Fecha_registro >= DATEADD(MINUTE, -?, SYSDATETIME())
            ) X
            GROUP BY X.Cb, X.Codigo_gas
            ORDER BY X.Cb
        """, codigo, minutos)

        filas = cursor.fetchall()

        etiquetas, ica, gases = [], {}, {}
        indice = {}

        for fecha, gas, conc, puntaje in filas:
            clave = fecha_texto(fecha)
            if clave not in indice:
                indice[clave] = len(etiquetas)
                etiquetas.append(clave)
                ica_valor = num(puntaje, 1)
                ica[clave] = ica_valor
            gases.setdefault(gas, {})[clave] = num(conc, 4)

        cursor.execute("""
            SELECT Codigo_gas, Nombre, Formula, Unidad, Umbral_medio, Umbral_malo
            FROM dbo.DIM_Gas ORDER BY Orden
        """)

        catalogo = [{
            "codigo": g[0], "nombre": g[1], "formula": g[2], "unidad": g[3],
            "umbral_medio": num(g[4]), "umbral_malo": num(g[5]),
        } for g in cursor.fetchall()]

        return jsonify({
            "ok": True,
            "etiquetas": etiquetas,
            "ica": [ica[e] for e in etiquetas],
            "gases": {
                codigo_gas: [valores.get(e) for e in etiquetas]
                for codigo_gas, valores in gases.items()
            },
            "catalogo": catalogo,
        }), 200

    except Exception as error:
        app.logger.exception("Error al consultar la serie")
        return jsonify({"ok": False, "error": str(error)}), 500

    finally:
        if conexion is not None:
            conexion.close()


# ==========================================
# MAPA: ÚLTIMA LECTURA POR UBICACIÓN
# ==========================================

@app.route("/api/mapa", methods=["GET"])
def mapa():

    conexion = None

    try:
        conexion = get_connection()
        cursor = conexion.cursor()

        cursor.execute("""
            SELECT Codigo_ubicacion, Ubicacion, Tipo_lugar, Latitud, Longitud,
                   Fecha, Lectura_ADC, Puntaje_ICA, Nivel, Gas_dominante,
                   Codigo_sensor
            FROM dbo.vw_UltimaPorUbicacion
            ORDER BY Ubicacion
        """)

        puntos = []

        for f in cursor.fetchall():
            valida, motivo = validar_lectura(f[5], float(f[6]), f[8] is not None)
            puntos.append({
                "codigo": f[0], "nombre": f[1], "tipo": f[2],
                "lat": float(f[3]), "lon": float(f[4]),
                "fecha": fecha_texto(f[5]),
                "puntaje": num(f[7], 1), "nivel": f[8],
                "gas_dominante": f[9], "sensor": f[10],
                "reciente": valida, "motivo": motivo,
            })

        return jsonify({"ok": True, "ubicaciones": puntos}), 200

    except Exception as error:
        app.logger.exception("Error al consultar el mapa")
        return jsonify({"ok": False, "error": str(error)}), 500

    finally:
        if conexion is not None:
            conexion.close()


# ==========================================
# RECEPCIÓN DE MEDICIONES DEL ESP32 (sin cambios)
# ==========================================

@app.route("/api/mediciones", methods=["POST"])
def registrar_medicion():
    """Recibir y registrar mediciones del ESP32."""

    if not validar_api_key():
        return jsonify({"ok": False, "error": "Clave API ausente o incorrecta"}), 401

    datos = request.get_json(silent=True)

    if not isinstance(datos, dict):
        return jsonify({"ok": False, "error": "Envía un objeto JSON válido"}), 400

    codigo_sensor = datos.get("codigo_sensor")
    codigo_ubicacion = datos.get("codigo_ubicacion")
    codigo_tipo = datos.get("codigo_tipo")
    valor = datos.get("valor")
    voltaje = datos.get("voltaje", 0)

    if not all([
        isinstance(codigo_sensor, str) and codigo_sensor.strip(),
        isinstance(codigo_ubicacion, str) and codigo_ubicacion.strip(),
        isinstance(codigo_tipo, str) and codigo_tipo.strip()
    ]):
        return jsonify({
            "ok": False,
            "error": "Se requieren codigo_sensor, codigo_ubicacion y codigo_tipo como textos no vacíos"
        }), 400

    try:
        valor = Decimal(str(valor))
        voltaje = Decimal(str(voltaje))

        if not valor.is_finite() or not voltaje.is_finite():
            raise InvalidOperation

        if voltaje < 0:
            return jsonify({"ok": False, "error": "El voltaje no puede ser negativo"}), 400

    except (InvalidOperation, ValueError, TypeError):
        return jsonify({"ok": False, "error": "valor y voltaje deben ser números válidos"}), 400

    conexion = None

    try:
        conexion = get_connection()
        cursor = conexion.cursor()

        cursor.execute(
            """
            EXEC dbo.usp_RegistrarMedida
                @Codigo_sensor = ?,
                @Codigo_ubicacion = ?,
                @Codigo_tipo = ?,
                @Valor = ?,
                @Voltaje = ?
            """,
            codigo_sensor.strip(), codigo_ubicacion.strip(),
            codigo_tipo.strip(), valor, voltaje
        )

        conexion.commit()

        return jsonify({
            "ok": True,
            "mensaje": "Medición registrada correctamente",
            "codigo_sensor": codigo_sensor,
            "codigo_ubicacion": codigo_ubicacion,
            "codigo_tipo": codigo_tipo,
            "valor": str(valor),
            "voltaje": str(voltaje)
        }), 201

    except Exception as error:

        if conexion is not None:
            conexion.rollback()

        app.logger.exception("Error al registrar la medición")
        return jsonify({"ok": False, "error": str(error)}), 500

    finally:
        if conexion is not None:
            conexion.close()


# ==========================================
# EJECUCIÓN DEL SERVIDOR
# ==========================================

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
