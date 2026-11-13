/* ==========================================================
   MONITOREO DE CALIDAD DEL AIRE  -  Base de datos v2
   Ejecutar en SSMS conectado a DESKTOP-G9RDFOS\SQLDEV

   * Crea una base NUEVA (DB_MonitoreoAire_v2). La actual no se toca.
   * Después cambia en .env:  DB_NAME=DB_MonitoreoAire_v2
   * El ESP32 y la ruta POST /api/mediciones no cambian.
   ========================================================== */

IF DB_ID('DB_MonitoreoAire_v2') IS NULL
    CREATE DATABASE DB_MonitoreoAire_v2;
GO
USE DB_MonitoreoAire_v2;
GO

/* ---------- 1. DIMENSIONES ---------- */

CREATE TABLE dbo.DIM_Ubicacion (
    Id_ubicacion     INT IDENTITY PRIMARY KEY,
    Codigo_ubicacion VARCHAR(30)   NOT NULL UNIQUE,
    Nombre           NVARCHAR(80)  NOT NULL,
    Tipo_lugar       NVARCHAR(40)  NOT NULL,
    Latitud          DECIMAL(9,6)  NOT NULL,
    Longitud         DECIMAL(9,6)  NOT NULL
);

CREATE TABLE dbo.DIM_Sensor (
    Id_sensor      INT IDENTITY PRIMARY KEY,
    Codigo_sensor  VARCHAR(30)   NOT NULL UNIQUE,
    Modelo         VARCHAR(20)   NOT NULL DEFAULT 'MQ-135',
    Vcc            DECIMAL(4,2)  NOT NULL DEFAULT 5.00,    -- alimentación del módulo
    RL_kohm        DECIMAL(8,2)  NOT NULL DEFAULT 10.00,   -- resistencia de carga del módulo
    R0_kohm        DECIMAL(10,3) NOT NULL DEFAULT 20.000,  -- Rs en aire limpio (CALIBRAR)
    Factor_divisor DECIMAL(6,3)  NOT NULL DEFAULT 1.000,   -- (R1+R2)/R2 si usas divisor de voltaje
    Es_simulado    BIT           NOT NULL DEFAULT 0,
    Activo         BIT           NOT NULL DEFAULT 1
);

CREATE TABLE dbo.DIM_tipo_Medicion (
    Id_tipo_medicion INT IDENTITY PRIMARY KEY,
    Codigo_tipo      VARCHAR(20)  NOT NULL UNIQUE,
    Descripcion      NVARCHAR(80) NOT NULL
);

/* Gases: concentración = Base * (Rs/R0) ^ -B
   Base = concentración típica de aire limpio, B = pendiente de la curva del datasheet.
   Umbrales: a partir de Medio y de Malo el gas cambia de nivel. Ajustables. */
CREATE TABLE dbo.DIM_Gas (
    Id_gas             INT IDENTITY PRIMARY KEY,
    Codigo_gas         VARCHAR(10)   NOT NULL UNIQUE,
    Nombre             NVARCHAR(40)  NOT NULL,
    Formula            NVARCHAR(12)  NOT NULL,
    Unidad             VARCHAR(10)   NOT NULL,
    Concentracion_base DECIMAL(18,6) NOT NULL,
    Pendiente_B        DECIMAL(8,4)  NOT NULL,
    Umbral_medio       DECIMAL(18,6) NOT NULL,
    Umbral_malo        DECIMAL(18,6) NOT NULL,
    Origen_curva       NVARCHAR(60)  NOT NULL,
    Orden              INT           NOT NULL
);

/* ---------- 2. HECHOS ---------- */

CREATE TABLE dbo.FACT_Medidas (
    Id_medida        BIGINT IDENTITY PRIMARY KEY,
    Id_sensor        INT NOT NULL REFERENCES dbo.DIM_Sensor(Id_sensor),
    Id_ubicacion     INT NOT NULL REFERENCES dbo.DIM_Ubicacion(Id_ubicacion),
    Id_tipo_medicion INT NOT NULL REFERENCES dbo.DIM_tipo_Medicion(Id_tipo_medicion),
    Valor_medido     DECIMAL(10,2) NOT NULL,
    Voltaje          DECIMAL(6,3)  NOT NULL DEFAULT 0,
    Fecha_registro   DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    Es_demo          BIT           NOT NULL DEFAULT 0
);
CREATE INDEX IX_Medidas_Fecha ON dbo.FACT_Medidas (Fecha_registro DESC);
CREATE INDEX IX_Medidas_Ubic  ON dbo.FACT_Medidas (Id_ubicacion, Fecha_registro DESC);

CREATE TABLE dbo.FACT_Calidad (
    Id_medida        BIGINT PRIMARY KEY
                     REFERENCES dbo.FACT_Medidas(Id_medida) ON DELETE CASCADE,
    Rs_kohm          DECIMAL(10,3) NOT NULL,
    Ratio_Rs_R0      DECIMAL(8,4)  NOT NULL,
    Puntaje_ICA      DECIMAL(5,2)  NOT NULL,   -- 0 a 100
    Nivel            VARCHAR(10)   NOT NULL,   -- Bueno / Medio / Malo
    Id_gas_dominante INT           NOT NULL REFERENCES dbo.DIM_Gas(Id_gas)
);

CREATE TABLE dbo.FACT_Gases (
    Id_medida     BIGINT NOT NULL
                  REFERENCES dbo.FACT_Medidas(Id_medida) ON DELETE CASCADE,
    Id_gas        INT    NOT NULL REFERENCES dbo.DIM_Gas(Id_gas),
    Concentracion DECIMAL(18,6) NOT NULL,
    Puntaje       DECIMAL(5,2)  NOT NULL,
    PRIMARY KEY (Id_medida, Id_gas)
);
GO

/* ---------- 3. DATOS BASE ---------- */

INSERT dbo.DIM_tipo_Medicion (Codigo_tipo, Descripcion)
VALUES ('ADC', N'Lectura analógica del ESP32 (0-4095)');

/* Coordenadas de EJEMPLO: cámbialas por las reales de cada lugar. */
INSERT dbo.DIM_Ubicacion (Codigo_ubicacion, Nombre, Tipo_lugar, Latitud, Longitud) VALUES
('UBICACION-001', N'Universidad',         N'Educativo',  4.8600, -74.0330),
('UBICACION-002', N'Parque principal',    N'Parque',     4.8625, -74.0590),
('UBICACION-003', N'Centro comercial',    N'Comercial',  4.8700, -74.0480),
('UBICACION-004', N'Parqueadero central', N'Parqueadero',4.8560, -74.0520),
('UBICACION-005', N'Avenida principal',   N'Vía',        4.8650, -74.0650),
('UBICACION-006', N'Plaza de mercado',    N'Mercado',    4.8590, -74.0620);

INSERT dbo.DIM_Sensor (Codigo_sensor, Es_simulado) VALUES
('MQ135-REAL-001', 0),
('MQ135-SIM-002',  1),
('MQ135-SIM-003',  1);

INSERT dbo.DIM_Gas
(Codigo_gas, Nombre, Formula, Unidad, Concentracion_base, Pendiente_B, Umbral_medio, Umbral_malo, Origen_curva, Orden)
VALUES
('CO2',  N'Dióxido de carbono', N'CO₂',  'ppm', 420,   2.769, 1000, 2000, N'Datasheet (ajuste)',        1),
('NH3',  N'Amoníaco',           N'NH₃',  'ppm', 0.5,   2.473, 10,   25,   N'Datasheet (ajuste)',        2),
('ALC',  N'Alcohol (etanol)',   N'C₂H₆O','ppm', 0.5,   3.180, 50,   200,  N'Datasheet (ajuste)',        3),
('BEN',  N'Benceno',            N'C₆H₆', 'ppm', 0.005, 3.445, 0.1,  1,    N'Curva de tolueno (aprox.)', 4),
('HUM',  N'Humo',               N'CO eq.','ppm',0.5,   3.937, 9,    35,   N'Curva de CO (aprox.)',      5),
('NOX',  N'Óxidos de nitrógeno',N'NOx',  'ppm', 0.02,  2.500, 0.05, 0.1,  N'Supuesto (sin curva)',      6);
GO

/* ---------- 4. FUNCIÓN DE PUNTAJE (0-100) ----------
   0-33 Bueno | 33-66 Medio | 66-100 Malo (según umbrales de cada gas) */
CREATE FUNCTION dbo.fn_Puntaje (@c DECIMAL(18,6), @medio DECIMAL(18,6), @malo DECIMAL(18,6))
RETURNS DECIMAL(5,2)
AS
BEGIN
    DECLARE @p FLOAT =
        CASE WHEN @c < @medio THEN 33.0 * @c / @medio
             WHEN @c < @malo  THEN 33.0 + 33.0 * (@c - @medio) / (@malo - @medio)
             ELSE 66.0 + 34.0 * (@c - @malo) / @malo END;
    RETURN CAST(CASE WHEN @p > 100 THEN 100 ELSE @p END AS DECIMAL(5,2));
END;
GO

/* ---------- 5. CÁLCULO DE CALIDAD (por rango de Id_medida) ---------- */
CREATE PROCEDURE dbo.usp_CalcularCalidad @IdDesde BIGINT, @IdHasta BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT M.Id_medida,
           Rs    = ((S.Vcc - V.Vm) / V.Vm) * S.RL_kohm,
           Ratio = (((S.Vcc - V.Vm) / V.Vm) * S.RL_kohm) / S.R0_kohm
    INTO #R
    FROM dbo.FACT_Medidas M
    JOIN dbo.DIM_Sensor S          ON S.Id_sensor = M.Id_sensor
    JOIN dbo.DIM_tipo_Medicion T   ON T.Id_tipo_medicion = M.Id_tipo_medicion
                                  AND T.Codigo_tipo = 'ADC'
    CROSS APPLY (SELECT Vm = M.Voltaje * S.Factor_divisor) V
    WHERE M.Id_medida BETWEEN @IdDesde AND @IdHasta
      AND V.Vm > 0.05 AND V.Vm < S.Vcc - 0.05
      AND NOT EXISTS (SELECT 1 FROM dbo.FACT_Calidad C WHERE C.Id_medida = M.Id_medida);

    DELETE FROM #R WHERE Ratio < 0.05 OR Ratio > 20;

    INSERT dbo.FACT_Gases (Id_medida, Id_gas, Concentracion, Puntaje)
    SELECT R.Id_medida, G.Id_gas, X.Conc,
           dbo.fn_Puntaje(X.Conc, G.Umbral_medio, G.Umbral_malo)
    FROM #R R
    CROSS JOIN dbo.DIM_Gas G
    CROSS APPLY (SELECT Conc = CAST(G.Concentracion_base *
                   POWER(CAST(R.Ratio AS FLOAT), -CAST(G.Pendiente_B AS FLOAT))
                   AS DECIMAL(18,6))) X;

    INSERT dbo.FACT_Calidad (Id_medida, Rs_kohm, Ratio_Rs_R0, Puntaje_ICA, Nivel, Id_gas_dominante)
    SELECT R.Id_medida, R.Rs, R.Ratio, D.Puntaje,
           CASE WHEN D.Puntaje >= 66 THEN 'Malo'
                WHEN D.Puntaje >= 33 THEN 'Medio' ELSE 'Bueno' END,
           D.Id_gas
    FROM #R R
    CROSS APPLY (SELECT TOP 1 FG.Id_gas, FG.Puntaje
                 FROM dbo.FACT_Gases FG
                 WHERE FG.Id_medida = R.Id_medida
                 ORDER BY FG.Puntaje DESC, FG.Id_gas) D;
END;
GO

/* ---------- 6. REGISTRAR MEDIDA (misma firma que la anterior) ---------- */
CREATE PROCEDURE dbo.usp_RegistrarMedida
    @Codigo_sensor    VARCHAR(30),
    @Codigo_ubicacion VARCHAR(30),
    @Codigo_tipo      VARCHAR(20),
    @Valor            DECIMAL(10,2),
    @Voltaje          DECIMAL(6,3) = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @IdS INT, @IdU INT, @IdT INT, @IdM BIGINT;

    SELECT @IdS = Id_sensor FROM dbo.DIM_Sensor WHERE Codigo_sensor = @Codigo_sensor AND Activo = 1;
    SELECT @IdU = Id_ubicacion FROM dbo.DIM_Ubicacion WHERE Codigo_ubicacion = @Codigo_ubicacion;
    SELECT @IdT = Id_tipo_medicion FROM dbo.DIM_tipo_Medicion WHERE Codigo_tipo = @Codigo_tipo;

    IF @IdS IS NULL THROW 50001, 'Sensor no registrado o inactivo', 1;
    IF @IdU IS NULL THROW 50002, 'Ubicación no registrada', 1;
    IF @IdT IS NULL THROW 50003, 'Tipo de medición no registrado', 1;

    IF @Voltaje = 0 SET @Voltaje = @Valor * 3.3 / 4095.0;

    INSERT dbo.FACT_Medidas (Id_sensor, Id_ubicacion, Id_tipo_medicion, Valor_medido, Voltaje)
    VALUES (@IdS, @IdU, @IdT, @Valor, @Voltaje);

    SET @IdM = SCOPE_IDENTITY();
    EXEC dbo.usp_CalcularCalidad @IdM, @IdM;
END;
GO

/* ---------- 7. CALIBRACIÓN DE R0 ----------
   Deja el sensor ~10 min en aire limpio y ejecuta:
   EXEC dbo.usp_CalibrarR0 'MQ135-REAL-001', 10;                       */
CREATE PROCEDURE dbo.usp_CalibrarR0 @Codigo_sensor VARCHAR(30), @Minutos INT = 10
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE S
       SET R0_kohm = X.RsProm
    FROM dbo.DIM_Sensor S
    CROSS APPLY (
        SELECT RsProm = AVG(((S.Vcc - M.Voltaje * S.Factor_divisor) / (M.Voltaje * S.Factor_divisor)) * S.RL_kohm)
        FROM dbo.FACT_Medidas M
        WHERE M.Id_sensor = S.Id_sensor
          AND M.Fecha_registro >= DATEADD(MINUTE, -@Minutos, SYSDATETIME())
          AND M.Voltaje * S.Factor_divisor > 0.05
          AND M.Voltaje * S.Factor_divisor < S.Vcc - 0.05
    ) X
    WHERE S.Codigo_sensor = @Codigo_sensor AND X.RsProm IS NOT NULL;

    SELECT Codigo_sensor, R0_kohm FROM dbo.DIM_Sensor WHERE Codigo_sensor = @Codigo_sensor;
END;
GO

/* ---------- 8. VISTAS PARA POWER BI ---------- */
CREATE VIEW dbo.vw_Lecturas AS
SELECT M.Id_medida, M.Fecha_registro AS Fecha,
       CAST(M.Fecha_registro AS DATE) AS Dia, DATEPART(HOUR, M.Fecha_registro) AS Hora,
       S.Codigo_sensor, S.Es_simulado,
       U.Codigo_ubicacion, U.Nombre AS Ubicacion, U.Tipo_lugar, U.Latitud, U.Longitud,
       M.Valor_medido AS Lectura_ADC, M.Voltaje,
       C.Ratio_Rs_R0, C.Puntaje_ICA, C.Nivel, G.Nombre AS Gas_dominante, M.Es_demo
FROM dbo.FACT_Medidas M
JOIN dbo.DIM_Sensor S    ON S.Id_sensor = M.Id_sensor
JOIN dbo.DIM_Ubicacion U ON U.Id_ubicacion = M.Id_ubicacion
LEFT JOIN dbo.FACT_Calidad C ON C.Id_medida = M.Id_medida
LEFT JOIN dbo.DIM_Gas G      ON G.Id_gas = C.Id_gas_dominante;
GO

CREATE VIEW dbo.vw_Gases AS
SELECT M.Id_medida, M.Fecha_registro AS Fecha, U.Nombre AS Ubicacion, U.Tipo_lugar,
       G.Codigo_gas, G.Nombre AS Gas, G.Formula, G.Unidad,
       FG.Concentracion, FG.Puntaje,
       CASE WHEN FG.Puntaje >= 66 THEN 'Malo' WHEN FG.Puntaje >= 33 THEN 'Medio' ELSE 'Bueno' END AS Nivel_gas,
       G.Umbral_medio, G.Umbral_malo
FROM dbo.FACT_Gases FG
JOIN dbo.FACT_Medidas M  ON M.Id_medida = FG.Id_medida
JOIN dbo.DIM_Gas G       ON G.Id_gas = FG.Id_gas
JOIN dbo.DIM_Ubicacion U ON U.Id_ubicacion = M.Id_ubicacion;
GO

CREATE VIEW dbo.vw_UltimaPorUbicacion AS
SELECT * FROM (
    SELECT L.*, ROW_NUMBER() OVER (PARTITION BY L.Codigo_ubicacion
                                   ORDER BY L.Fecha DESC, L.Id_medida DESC) AS rn
    FROM dbo.vw_Lecturas L
) Z WHERE rn = 1;
GO

/* ---------- 9. DATOS DE DEMOSTRACIÓN ----------
   2 días, 1 lectura cada 5 min, 3 sensores. Cada sensor alterna entre dos lugares
   cada 4 horas. Se marcan con Es_demo = 1 y se borran con:
   DELETE FROM dbo.FACT_Medidas WHERE Es_demo = 1;                     */
DECLARE @Fin DATETIME2(0) = SYSDATETIME();
DECLARE @IdADC INT = (SELECT Id_tipo_medicion FROM dbo.DIM_tipo_Medicion WHERE Codigo_tipo = 'ADC');

DECLARE @Plan TABLE (Id_sensor INT, Bloque INT, Id_ubicacion INT, Base_r FLOAT, Amp FLOAT);
INSERT @Plan
SELECT S.Id_sensor, P.Bloque, U.Id_ubicacion, P.Base_r, P.Amp
FROM (VALUES
  ('MQ135-REAL-001',0,'UBICACION-001',0.88,0.07), ('MQ135-REAL-001',1,'UBICACION-002',0.97,0.03),
  ('MQ135-SIM-002', 0,'UBICACION-003',0.75,0.10), ('MQ135-SIM-002', 1,'UBICACION-004',0.52,0.12),
  ('MQ135-SIM-003', 0,'UBICACION-005',0.62,0.10), ('MQ135-SIM-003', 1,'UBICACION-006',0.70,0.08)
) P(Sensor, Bloque, Ubic, Base_r, Amp)
JOIN dbo.DIM_Sensor S    ON S.Codigo_sensor = P.Sensor
JOIN dbo.DIM_Ubicacion U ON U.Codigo_ubicacion = P.Ubic;

;WITH N AS (
    SELECT TOP (576) n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
SELECT S.Id_sensor, S.Vcc, S.RL_kohm, S.R0_kohm, S.Factor_divisor,
       P.Id_ubicacion,
       Fecha = DATEADD(MINUTE, -5 * N.n, @Fin),
       r = P.Base_r
           - P.Amp * (CASE WHEN DATEPART(HOUR, DATEADD(MINUTE, -5 * N.n, @Fin)) IN (7,8,9,17,18,19) THEN 1.0
                           WHEN DATEPART(HOUR, DATEADD(MINUTE, -5 * N.n, @Fin)) BETWEEN 10 AND 16   THEN 0.5
                           ELSE 0.1 END)
           + 0.03 * ((ABS(CHECKSUM(NEWID())) % 2001 - 1000) / 1000.0)
INTO #Demo
FROM N
CROSS JOIN dbo.DIM_Sensor S
JOIN @Plan P ON P.Id_sensor = S.Id_sensor
            AND P.Bloque = (DATEDIFF(HOUR, '20000101', DATEADD(MINUTE, -5 * N.n, @Fin)) / 4) % 2;

INSERT dbo.FACT_Medidas (Id_sensor, Id_ubicacion, Id_tipo_medicion, Valor_medido, Voltaje, Fecha_registro, Es_demo)
SELECT D.Id_sensor, D.Id_ubicacion, @IdADC,
       CAST(Y.Vpin / 3.3 * 4095 AS DECIMAL(10,2)),
       CAST(Y.Vpin AS DECIMAL(6,3)),
       D.Fecha, 1
FROM #Demo D
CROSS APPLY (SELECT rr = CASE WHEN D.r < 0.25 THEN 0.25 WHEN D.r > 1.1 THEN 1.1 ELSE D.r END) K
CROSS APPLY (SELECT Vpin = (D.Vcc * D.RL_kohm / (K.rr * D.R0_kohm + D.RL_kohm)) / D.Factor_divisor) Y;

DECLARE @Min BIGINT, @Max BIGINT;
SELECT @Min = MIN(Id_medida), @Max = MAX(Id_medida) FROM dbo.FACT_Medidas WHERE Es_demo = 1;
EXEC dbo.usp_CalcularCalidad @Min, @Max;

DROP TABLE #Demo;

/* Verificación rápida */
SELECT COUNT(*) AS Medidas FROM dbo.FACT_Medidas;
SELECT Ubicacion, Nivel, Puntaje_ICA, Gas_dominante, Fecha FROM dbo.vw_UltimaPorUbicacion;
GO
