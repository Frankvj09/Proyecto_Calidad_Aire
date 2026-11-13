# Puesta en marcha

## 1. Base de datos
1. Abre `sql/01_base_datos.sql` en SSMS (servidor `DESKTOP-G9RDFOS\SQLDEV`) y ejecútalo completo.
   Crea `DB_MonitoreoAire_v2` con 6 lugares, 3 sensores, 6 gases y 2 días de datos de demostración.
   Tu base anterior no se modifica.
2. En `.env` cambia `DB_NAME=DB_MonitoreoAire_v2`.
3. Cambia las coordenadas de `DIM_Ubicacion` por las reales de cada lugar.

## 2. Servidor web
Copia estos archivos sobre tu proyecto (reemplazan a los anteriores):
`app.py`, `templates/index.html`, `templates/navbar.html`, `static/js/principal.js`.
Añade los nuevos: `static/js/panel.js`, `static/css/panel.css`, `simulador.py`.
`base.html`, `database.py`, `estilos.css` y el código del ESP32 no cambian.

```
python app.py
python simulador.py      # opcional, en otra terminal: mueve los sensores simulados
```

## 3. Calibrar el sensor real (importante)
Con el MQ-135 encendido ~24 h de precalentamiento y en aire limpio/ventilado, 10 minutos:
```sql
EXEC dbo.usp_CalibrarR0 'MQ135-REAL-001', 10;
```
Sin esto, el nivel del sensor real no es confiable. Si tu módulo entrega más de 3,3 V
en AO, usa un divisor de voltaje y ajusta `Factor_divisor` en `DIM_Sensor`
(por ejemplo 1.5 con 10 kΩ + 20 kΩ).

## 4. Power BI
Un archivo .pbix no se puede generar fuera de Power BI Desktop; esta es la receta (≈15 min).

**Datos:** Obtener datos → SQL Server → `DESKTOP-G9RDFOS\SQLDEV` / `DB_MonitoreoAire_v2` →
importar `vw_Lecturas`, `vw_Gases`, `vw_UltimaPorUbicacion`.

**Medidas DAX**
```
Puntaje actual = MAX ( vw_UltimaPorUbicacion[Puntaje_ICA] )
Promedio ICA   = AVERAGE ( vw_Lecturas[Puntaje_ICA] )
% Malo         = DIVIDE ( CALCULATE ( COUNTROWS ( vw_Lecturas ), vw_Lecturas[Nivel] = "Malo" ), COUNTROWS ( vw_Lecturas ) )
Concentración  = AVERAGE ( vw_Gases[Concentracion] )
```

**Visuales**
- Medidor: `Puntaje actual`, mínimo 0, máximo 100, objetivo 33 (verde hasta 33, amarillo hasta 66, rojo después).
- Líneas: eje X `vw_Lecturas[Fecha]`, valor `Promedio ICA`; añade líneas constantes en 33 y 66 (panel Análisis).
- Líneas por gas: eje `vw_Gases[Fecha]`, valor `Concentración`, segmentación por `Gas`.
- Mapa: `vw_UltimaPorUbicacion` con Latitud/Longitud, color según `Nivel`, tamaño `Puntaje_ICA`.
- Segmentaciones: `Ubicacion`, `Tipo_lugar`, `Dia`; una barra por `Nivel` y `Hora`.

**Actualización:** con SQL Server local el informe publicado solo se actualiza con una
puerta de enlace de datos local (gateway) y actualización programada. La frecuencia
depende de tu licencia. Las lecturas cada 30 s se ven en la página web; Power BI queda
para el análisis histórico.
Después de publicar con "Publicar en la web", reemplaza la URL del `<iframe>` en `index.html`.
