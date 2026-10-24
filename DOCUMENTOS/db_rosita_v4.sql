-- =====================================================================
-- DB_ROSITA v4 — SCRIPT COMPLETO (reemplaza a DB_ROSITA v3)
-- Motor: MySQL 8.0+
--
-- Concordancia con: Historias_Usuario_POS_Libreria_Rosita_v1.3.xlsx
--   HU-01..HU-19 | POS.RF-01..POS.RF-61 | RN-001..RN-025 | RNF-01..RNF-16
--
-- Cambios frente a v3 (detalle en cada bloque):
--   [C1] PROMOCION.tipo_descuento VARCHAR(10 -> 12)   -> HU-18 / RN-022 ('MONTO_FIJO' no cabia)
--   [C2] ESTADO CAMPANA 'Programada'                  -> HU-18 / RN-022
--   [C3] DETALLE_DEVOLUCION UNIQUE(id_devolucion,id_detalle) -> RN-019 (no devolver dos veces)
--   [C4] DEVOLUCION.id_venta nullable + id_reserva    -> RN-019 / RN-021 (devoluciones y adelantos)
--   [C5] DEVOLUCION.id_usuario_autoriza nullable      -> RN-017 (el Dueno no se autoriza a si mismo)
--   [C6] PAGO.id_reserva + id_venta nullable          -> RN-010 / RN-021 (adelanto entra a la caja)
--   [C7] TRIGGER rechaza sesion 'Arqueada'            -> RN-020 (no anular tras arquear)
--   [C8] USUARIO: ID 1 = Dueno, ID 2 = Vendedor       -> HU-01 (login por ID numerico)
--   [C9] CHECKs extra (montos, fechas, promociones)   -> integridad general
--   [C10] Indices de lectura y referencia_temporal unica -> RNF-01 / RNF-02 / RN-023
-- =====================================================================
CREATE DATABASE IF NOT EXISTS DB_ROSITA;
USE DB_ROSITA;

-- =====================================================================
-- ESTADOS (catálogo global, controlado por entidad)
-- =====================================================================
CREATE TABLE ESTADO(
    id_estado INT AUTO_INCREMENT PRIMARY KEY,
    entidad VARCHAR(30) NOT NULL,
    nombre_estado VARCHAR(30) NOT NULL,
    UNIQUE (entidad, nombre_estado)
);

-- =====================================================================
-- ROLES / USUARIOS
-- =====================================================================
CREATE TABLE ROL(
    id_rol INT AUTO_INCREMENT PRIMARY KEY,
    nombre_rol VARCHAR(30) NOT NULL UNIQUE,
    descripcion VARCHAR(100) NULL
);

CREATE TABLE USUARIO(
    id_usuario INT AUTO_INCREMENT PRIMARY KEY,
    id_rol INT NOT NULL,
    id_estado INT NOT NULL,
    nombres VARCHAR(100) NOT NULL,
    apellido_paterno VARCHAR(100) NOT NULL,
    usuario VARCHAR(30) NOT NULL UNIQUE,   -- HU-01: login por ID numerico (ej. 654321)
    contrasena VARCHAR(255) NOT NULL,      -- RNF-05: hash con sal, nunca texto plano
    FOREIGN KEY (id_rol) REFERENCES ROL(id_rol),
    FOREIGN KEY (id_estado) REFERENCES ESTADO(id_estado)
);

-- =====================================================================
-- CLIENTES (HU-05: autocompletado por documento)
-- =====================================================================
CREATE TABLE CLIENTE(
    id_cliente INT AUTO_INCREMENT PRIMARY KEY,
    id_estado INT NOT NULL,
    tipo_documento VARCHAR(12) NOT NULL,      -- DNI / CARNET
    numero_documento VARCHAR(12) NOT NULL,    -- RN-008: DNI = 8 digitos, carnet = 6 a 12
    nombre_cliente VARCHAR(100) NULL,
    apellido_paterno VARCHAR(100) NULL,
    apellido_materno VARCHAR(100) NULL,
    razon_social VARCHAR(150) NULL,
    direccion VARCHAR(200) NULL,
    correo VARCHAR(100) NULL,
    UNIQUE (tipo_documento, numero_documento),
    FOREIGN KEY (id_estado) REFERENCES ESTADO(id_estado)
);

-- =====================================================================
-- CATALOGO / STOCK (RN-001, RN-021)
-- =====================================================================
CREATE TABLE CATEGORIA(
    id_categoria INT AUTO_INCREMENT PRIMARY KEY,
    nombre_categoria VARCHAR(50) NOT NULL,
    descripcion VARCHAR(200) NOT NULL
);

CREATE TABLE PRODUCTOS(
    id_producto INT AUTO_INCREMENT PRIMARY KEY,
    id_categoria INT NOT NULL,
    id_estado INT NOT NULL,
    codigo_producto VARCHAR(20) UNIQUE NOT NULL,  -- SKU
    nombre_producto VARCHAR(50) NOT NULL,
    descripcion VARCHAR(200) NOT NULL,
    precio_unitario DECIMAL(10,2) NOT NULL,
    CHECK (precio_unitario >= 0),                                -- [C9]
    FOREIGN KEY (id_categoria) REFERENCES CATEGORIA(id_categoria),
    FOREIGN KEY (id_estado) REFERENCES ESTADO(id_estado)
);

-- [C9] stock minimo por producto y disponible = cantidad_actual - cantidad_reservada
CREATE TABLE STOCK(
    id_stock INT AUTO_INCREMENT PRIMARY KEY,
    id_producto INT NOT NULL UNIQUE,
    cantidad_actual INT NOT NULL DEFAULT 0,
    cantidad_reservada INT NOT NULL DEFAULT 0,
    stock_minimo INT NOT NULL DEFAULT 0,     -- HU-14: alerta de stock bajo (<= 5 en ambar)
    CHECK (cantidad_actual >= 0),
    CHECK (cantidad_reservada >= 0 AND cantidad_reservada <= cantidad_actual),
    FOREIGN KEY (id_producto) REFERENCES PRODUCTOS(id_producto)
);

-- =====================================================================
-- CAMPANAS / PROMOCIONES (HU-18, RN-022)
--   [C1] tipo_descuento VARCHAR(12): 'MONTO_FIJO' necesita 11 caracteres
--   [C2] estado 'Programada' antes de 'Activa'
-- =====================================================================
CREATE TABLE CAMPANA(
    id_campana INT AUTO_INCREMENT PRIMARY KEY,
    id_estado INT NOT NULL,
    nombre_campana VARCHAR(80) NOT NULL,
    descripcion VARCHAR(200) NULL,
    fecha_inicio DATE NOT NULL,
    fecha_fin DATE NOT NULL,
    CHECK (fecha_fin >= fecha_inicio),                         -- [C9]
    FOREIGN KEY (id_estado) REFERENCES ESTADO(id_estado)
);

CREATE TABLE PROMOCION(
    id_promocion INT AUTO_INCREMENT PRIMARY KEY,
    id_campana INT NOT NULL,
    id_producto INT NULL,
    id_categoria INT NULL,
    tipo_descuento VARCHAR(12) NOT NULL,     -- [C1]
    valor_descuento DECIMAL(10,2) NOT NULL,
    cantidad_minima INT NOT NULL DEFAULT 1,
    CHECK (tipo_descuento IN ('PORCENTAJE','MONTO_FIJO')),    -- [C1]
    CHECK (valor_descuento > 0),
    CHECK (cantidad_minima >= 1),
    CHECK ((id_producto IS NOT NULL AND id_categoria IS NULL) OR
           (id_producto IS NULL AND id_categoria IS NOT NULL)),-- [C9] alcance exclusivo
    FOREIGN KEY (id_campana) REFERENCES CAMPANA(id_campana),
    FOREIGN KEY (id_producto) REFERENCES PRODUCTOS(id_producto),
    FOREIGN KEY (id_categoria) REFERENCES CATEGORIA(id_categoria)
);

-- =====================================================================
-- METODOS DE PAGO: solo Efectivo y Transferencia (SIN Tarjeta/POS)
-- =====================================================================
CREATE TABLE TIPO_PAGO(
    id_metodo INT AUTO_INCREMENT PRIMARY KEY,
    metodo_pago VARCHAR(20) NOT NULL UNIQUE
);

-- =====================================================================
-- CAJAS (Caja 1 = Dueno, Cajas 2/3/4 = Vendedores)  RN-015 / RN-025
-- =====================================================================
CREATE TABLE CAJA(
    id_caja INT AUTO_INCREMENT PRIMARY KEY,
    id_estado INT NOT NULL,
    numero_caja INT NOT NULL UNIQUE,
    nombre_caja VARCHAR(30) NOT NULL,
    FOREIGN KEY (id_estado) REFERENCES ESTADO(id_estado)
);

-- =====================================================================
-- SESION DE CAJA: apertura, arqueo y cierre (X out)   HU-02/10/11/12, RN-007/010
-- =====================================================================
CREATE TABLE SESION_CAJA(
    id_sesion INT AUTO_INCREMENT PRIMARY KEY,
    id_usuario INT NOT NULL,
    id_caja INT NOT NULL,
    id_estado INT NOT NULL,               -- Abierta / Arqueada / Cerrada
    fecha_apertura DATETIME NOT NULL,
    fondo_inicial DECIMAL(10,2) NOT NULL,
    -- arqueo (solo el efectivo se cuenta fisicamente; HU-10 / RN-010)
    fecha_arqueo DATETIME NULL,
    efectivo_esperado DECIMAL(10,2) NULL,
    efectivo_contado DECIMAL(10,2) NULL,
    dif_efectivo DECIMAL(10,2) NULL,
    observacion VARCHAR(200) NULL,
    -- cierre (X out)  HU-12
    fecha_cierre DATETIME NULL,
    fondo_final DECIMAL(10,2) NULL,
    dif_fondo DECIMAL(10,2) NULL,
    CHECK (fondo_inicial >= 0),
    FOREIGN KEY (id_usuario) REFERENCES USUARIO(id_usuario),
    FOREIGN KEY (id_caja) REFERENCES CAJA(id_caja),
    FOREIGN KEY (id_estado) REFERENCES ESTADO(id_estado),
    UNIQUE (id_caja, fecha_apertura)          -- [C10] una sola apertura por caja y momento
);

-- =====================================================================
-- VENTA   HU-03..HU-08, HU-19
-- Estados: En espera / Registrada / Sin comprobante / Consolidada /
--          Devuelta / Parcialmente devuelta / Anulada
-- =====================================================================
CREATE TABLE VENTA(
    id_venta INT AUTO_INCREMENT PRIMARY KEY,
    id_cliente INT NULL,
    id_usuario INT NOT NULL,
    id_sesion INT NOT NULL,
    id_reserva INT NULL,
    id_estado INT NOT NULL,
    id_comprobante_consolidado INT NULL,   -- HU-08: apunta a la boleta/ticket global
    correlativo_venta VARCHAR(20) NULL UNIQUE,
    fecha_venta DATETIME NOT NULL,
    subtotal DECIMAL(10,2) NOT NULL,
    descuento_total DECIMAL(10,2) NOT NULL DEFAULT 0,   -- RN-022
    total_venta DECIMAL(10,2) NOT NULL,
    CHECK (subtotal >= 0 AND descuento_total >= 0 AND total_venta >= 0),   -- [C9]
    FOREIGN KEY (id_cliente) REFERENCES CLIENTE(id_cliente),
    FOREIGN KEY (id_usuario) REFERENCES USUARIO(id_usuario),
    FOREIGN KEY (id_sesion) REFERENCES SESION_CAJA(id_sesion),
    FOREIGN KEY (id_estado) REFERENCES ESTADO(id_estado),
    INDEX idx_venta_fecha (fecha_venta),               -- [C10] HU-13
    INDEX idx_venta_sesion (id_sesion)                 -- [C10] RN-025
);

CREATE TABLE DETALLE_VENTA(
    id_detalle INT AUTO_INCREMENT PRIMARY KEY,
    id_venta INT NOT NULL,
    id_producto INT NOT NULL,
    id_promocion INT NULL,               -- RN-022: descuento aplicado en esa linea
    cantidad INT NOT NULL,
    precio_unitario DECIMAL(10,2) NOT NULL,
    descuento DECIMAL(10,2) NOT NULL DEFAULT 0,
    subtotal DECIMAL(10,2) NOT NULL,
    CHECK (cantidad > 0),                                 -- [C9]
    FOREIGN KEY (id_venta) REFERENCES VENTA(id_venta),
    FOREIGN KEY (id_producto) REFERENCES PRODUCTOS(id_producto),
    FOREIGN KEY (id_promocion) REFERENCES PROMOCION(id_promocion)
);

-- =====================================================================
-- RESERVAS (HU-16, RN-021): compromiso de stock sin descuento fisico
-- =====================================================================
CREATE TABLE RESERVA(
    id_reserva INT AUTO_INCREMENT PRIMARY KEY,
    id_cliente INT NULL,
    id_usuario INT NOT NULL,
    id_sesion INT NOT NULL,
    id_estado INT NOT NULL,   -- Pendiente de entrega / Entrega parcial / Entregada / Cancelada / Vencida
    fecha_reserva DATETIME NOT NULL,
    fecha_limite DATE NULL,
    monto_adelanto DECIMAL(10,2) NOT NULL DEFAULT 0,
    observacion VARCHAR(200) NULL,
    CHECK (monto_adelanto >= 0),
    FOREIGN KEY (id_cliente) REFERENCES CLIENTE(id_cliente),
    FOREIGN KEY (id_usuario) REFERENCES USUARIO(id_usuario),
    FOREIGN KEY (id_sesion) REFERENCES SESION_CAJA(id_sesion),
    FOREIGN KEY (id_estado) REFERENCES ESTADO(id_estado)
);

CREATE TABLE DETALLE_RESERVA(
    id_detalle_reserva INT AUTO_INCREMENT PRIMARY KEY,
    id_reserva INT NOT NULL,
    id_producto INT NOT NULL,
    cantidad INT NOT NULL,
    cantidad_entregada INT NOT NULL DEFAULT 0,
    precio_unitario DECIMAL(10,2) NOT NULL,
    CHECK (cantidad > 0 AND cantidad_entregada >= 0 AND cantidad_entregada <= cantidad),
    FOREIGN KEY (id_reserva) REFERENCES RESERVA(id_reserva),
    FOREIGN KEY (id_producto) REFERENCES PRODUCTOS(id_producto)
);

ALTER TABLE VENTA
    ADD FOREIGN KEY (id_reserva) REFERENCES RESERVA(id_reserva);

-- =====================================================================
-- PAGO (efectivo / transferencia)  HU-04, HU-10, RN-002/003/010/021
--   [C6] id_reserva: el adelanto de una reserva entra a la sesion de caja
--        (RN-010: el efectivo esperado debe incluir los adelantos cobrados).
--        id_venta pasa a NULL para permitir ese caso.
--   Unicidad del numero de operacion dentro del mismo canal (RN-023):
--   canal_unico agrupa id_metodo + canal_transferencia.
-- =====================================================================
CREATE TABLE PAGO(
    id_pago INT AUTO_INCREMENT PRIMARY KEY,
    id_venta INT NULL,
    id_reserva INT NULL,                                      -- [C6]
    id_metodo INT NOT NULL,
    canal_transferencia VARCHAR(10) NULL,
    monto DECIMAL(10,2) NOT NULL,
    monto_recibido DECIMAL(10,2) NULL,
    vuelto DECIMAL(10,2) NULL,
    numero_operacion VARCHAR(30) NULL,
    pago_validado TINYINT(1) NOT NULL DEFAULT 0,
    canal_unico VARCHAR(12) GENERATED ALWAYS AS (
        CASE WHEN numero_operacion IS NULL THEN NULL
             ELSE CONCAT(id_metodo, '-', COALESCE(canal_transferencia,'NA'))
        END
    ) STORED,
    fecha_pago DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,   -- [C10] para el arqueo por dia
    CHECK (canal_transferencia IN ('YAPE','PLIN','BANCARIA') OR canal_transferencia IS NULL),
    CHECK (monto > 0),
    -- [C4/C6] un pago es de una venta o de una reserva, nunca de ambas
    CHECK ((id_venta IS NOT NULL AND id_reserva IS NULL) OR
           (id_venta IS NULL AND id_reserva IS NOT NULL)),     -- [C9]
    UNIQUE KEY uq_pago_operacion (canal_unico, numero_operacion),
    FOREIGN KEY (id_venta) REFERENCES VENTA(id_venta),
    FOREIGN KEY (id_reserva) REFERENCES RESERVA(id_reserva),  -- [C6]
    FOREIGN KEY (id_metodo) REFERENCES TIPO_PAGO(id_metodo),
    INDEX idx_pago_sesion_fecha (fecha_pago)                  -- [C10] arqueo rapido
);

-- =====================================================================
-- DESEMBOLSO (efectivo del dia, fuera del fondo de caja)  HU-11, RN-024
-- =====================================================================
CREATE TABLE DESEMBOLSO(
    id_desembolso INT AUTO_INCREMENT PRIMARY KEY,
    id_sesion INT NOT NULL,
    id_usuario INT NOT NULL,
    fecha_desembolso DATETIME NOT NULL,
    monto DECIMAL(10,2) NOT NULL,
    descripcion VARCHAR(200) NOT NULL,
    CHECK (monto > 0),
    FOREIGN KEY (id_sesion) REFERENCES SESION_CAJA(id_sesion),
    FOREIGN KEY (id_usuario) REFERENCES USUARIO(id_usuario)
);

-- =====================================================================
-- DEVOLUCION / CAMBIO / ANULACION   HU-09, HU-19, RN-017/019/020
--   tipo_operacion = 'ANULACION': mismo dia y caja sin arquear/cerrar (ver trigger)
--   [C4] id_venta nullable + id_reserva para devoluciones ligadas a reservas
--   [C5] id_usuario_autoriza nullable: si opera el Dueno no se exige segunda firma (RN-017)
-- =====================================================================
CREATE TABLE DEVOLUCION(
    id_devolucion INT AUTO_INCREMENT PRIMARY KEY,
    id_venta INT NULL,                                        -- [C4]
    id_reserva INT NULL,                                      -- [C4]
    id_sesion INT NOT NULL,
    id_usuario INT NOT NULL,
    id_usuario_autoriza INT NULL,                             -- [C5]
    id_estado INT NOT NULL,
    tipo_operacion VARCHAR(10) NOT NULL,
    es_total TINYINT(1) NOT NULL DEFAULT 0,
    motivo VARCHAR(200) NOT NULL,                             -- RN-019/RN-020: obligatorio
    fecha_devolucion DATETIME NOT NULL,
    monto_devuelto DECIMAL(10,2) NOT NULL DEFAULT 0,
    id_venta_cambio INT NULL,
    banco VARCHAR(20) NULL,
    titular_cuenta VARCHAR(100) NULL,
    tipo_cuenta VARCHAR(10) NULL,
    numero_cuenta VARCHAR(20) NULL,
    CHECK (tipo_operacion IN ('DEVOLUCION','CAMBIO','ANULACION')),
    CHECK (monto_devuelto >= 0),
    -- [C4] o es de una venta o de una reserva, no de ambas
    CHECK ((id_venta IS NOT NULL AND id_reserva IS NULL) OR
           (id_venta IS NULL AND id_reserva IS NOT NULL)),
    FOREIGN KEY (id_venta) REFERENCES VENTA(id_venta),
    FOREIGN KEY (id_reserva) REFERENCES RESERVA(id_reserva),  -- [C4]
    FOREIGN KEY (id_sesion) REFERENCES SESION_CAJA(id_sesion),
    FOREIGN KEY (id_usuario) REFERENCES USUARIO(id_usuario),
    FOREIGN KEY (id_usuario_autoriza) REFERENCES USUARIO(id_usuario),
    FOREIGN KEY (id_estado) REFERENCES ESTADO(id_estado),
    FOREIGN KEY (id_venta_cambio) REFERENCES VENTA(id_venta)
);

-- [C3] un mismo item no se puede devolver dos veces (RN-019)
CREATE TABLE DETALLE_DEVOLUCION(
    id_detalle_devolucion INT AUTO_INCREMENT PRIMARY KEY,
    id_devolucion INT NOT NULL,
    id_detalle INT NOT NULL,
    cantidad INT NOT NULL,
    estado_producto VARCHAR(10) NOT NULL,   -- 'REINGRESO' / 'MERMA' (HU-09)
    CHECK (cantidad > 0),
    CHECK (estado_producto IN ('REINGRESO','MERMA')),
    UNIQUE KEY uq_detdev_devolucion_detalle (id_devolucion, id_detalle),   -- [C3]
    FOREIGN KEY (id_devolucion) REFERENCES DEVOLUCION(id_devolucion),
    FOREIGN KEY (id_detalle) REFERENCES DETALLE_VENTA(id_detalle)
);

-- =====================================================================
-- KARDEX (entradas, salidas y saldo)   HU-14, HU-15, RN-005
-- =====================================================================
CREATE TABLE MOVIMIENTO_STOCK(
    id_movimiento INT AUTO_INCREMENT PRIMARY KEY,
    id_stock INT NOT NULL,
    id_usuario INT NOT NULL,
    id_venta INT NULL,
    id_devolucion INT NULL,
    tipo_movimiento VARCHAR(20) NOT NULL,
    cantidad INT NOT NULL,
    saldo_resultante INT NOT NULL,
    fecha_movimiento DATETIME NOT NULL,
    CHECK (tipo_movimiento IN
        ('venta','devolucion_entrada','devolucion_merma',
         'cambio_entrada','cambio_salida','anulacion','reserva_compromiso',
         'reserva_entrega','reserva_liberacion')),
    FOREIGN KEY (id_stock) REFERENCES STOCK(id_stock),
    FOREIGN KEY (id_usuario) REFERENCES USUARIO(id_usuario),
    FOREIGN KEY (id_venta) REFERENCES VENTA(id_venta),
    FOREIGN KEY (id_devolucion) REFERENCES DEVOLUCION(id_devolucion),
    INDEX idx_kardex_stock_fecha (id_stock, fecha_movimiento)   -- [C10] HU-14
);

-- =====================================================================
-- COMPROBANTES   HU-04/05/06/08/19, RN-004/009/018
-- =====================================================================
CREATE TABLE NEGOCIO(
    id_negocio INT AUTO_INCREMENT PRIMARY KEY,
    id_estado INT NOT NULL,
    ruc CHAR(11) NOT NULL UNIQUE,
    razon_social VARCHAR(150) NOT NULL,
    nombre_comercial VARCHAR(100) NULL,
    direccion_fiscal VARCHAR(200) NOT NULL,
    categoria_nrus TINYINT NOT NULL DEFAULT 1,
    tipo_comprobante_defecto VARCHAR(2) NOT NULL DEFAULT '03',  -- HU-08: '03' Boleta / '12' Ticket
    FOREIGN KEY (id_estado) REFERENCES ESTADO(id_estado)
);

CREATE TABLE TIPO_COMPROBANTE(
    id_tipo_comprobante INT AUTO_INCREMENT PRIMARY KEY,
    codigo_sunat VARCHAR(2) NOT NULL UNIQUE,
    nombre_tipo VARCHAR(30) NOT NULL,
    prefijo_serie CHAR(1) NOT NULL
);

CREATE TABLE COMPROBANTE(
    id_comprobante INT AUTO_INCREMENT PRIMARY KEY,
    id_venta INT NULL UNIQUE,
    id_negocio INT NOT NULL,
    id_tipo_comprobante INT NOT NULL,
    id_cliente INT NULL,
    id_usuario INT NOT NULL,
    id_estado INT NOT NULL,               -- Emitido / Pendiente de envio / Anulado
    es_consolidado TINYINT(1) NOT NULL DEFAULT 0,   -- HU-08: boleta/ticket global
    serie VARCHAR(4) NOT NULL,
    numero INT NOT NULL,
    fecha_emision DATETIME NOT NULL,
    moneda CHAR(3) NOT NULL DEFAULT 'PEN',
    adquirente_tipo_documento VARCHAR(12) NULL,
    adquirente_numero_documento VARCHAR(12) NULL,
    adquirente_nombre VARCHAR(150) NULL,
    correo_envio VARCHAR(100) NULL,
    fecha_envio_correo DATETIME NULL,
    descuento_total DECIMAL(10,2) NOT NULL DEFAULT 0,
    importe_total DECIMAL(10,2) NOT NULL,
    UNIQUE (serie, numero),                                 -- RN-018
    CHECK (importe_total >= 0),
    FOREIGN KEY (id_venta) REFERENCES VENTA(id_venta),
    FOREIGN KEY (id_negocio) REFERENCES NEGOCIO(id_negocio),
    FOREIGN KEY (id_tipo_comprobante) REFERENCES TIPO_COMPROBANTE(id_tipo_comprobante),
    FOREIGN KEY (id_cliente) REFERENCES CLIENTE(id_cliente),
    FOREIGN KEY (id_usuario) REFERENCES USUARIO(id_usuario),
    FOREIGN KEY (id_estado) REFERENCES ESTADO(id_estado)
);

CREATE TABLE DETALLE_COMPROBANTE(
    id_detalle_comprobante INT AUTO_INCREMENT PRIMARY KEY,
    id_comprobante INT NOT NULL,
    id_producto INT NOT NULL,
    descripcion VARCHAR(200) NOT NULL,
    cantidad INT NOT NULL,
    precio_unitario DECIMAL(10,2) NOT NULL,
    descuento DECIMAL(10,2) NOT NULL DEFAULT 0,
    importe DECIMAL(10,2) NOT NULL,
    CHECK (cantidad > 0),
    FOREIGN KEY (id_comprobante) REFERENCES COMPROBANTE(id_comprobante),
    FOREIGN KEY (id_producto) REFERENCES PRODUCTOS(id_producto)
);

-- Ventas < S/ 5.00 consolidadas apuntan a su boleta/ticket global (HU-08)
ALTER TABLE VENTA
    ADD FOREIGN KEY (id_comprobante_consolidado) REFERENCES COMPROBANTE(id_comprobante);

-- =====================================================================
-- LOG DE FALLAS (HU-17, RN-023 idempotencia)
--   [C10] referencia_temporal unica por tipo de operacion:
--   un reintento sobre una operacion ya registrada NO se duplica.
-- =====================================================================
CREATE TABLE LOG_ERROR_OPERACION(
    id_log INT AUTO_INCREMENT PRIMARY KEY,
    id_usuario INT NULL,
    id_sesion INT NULL,
    tipo_operacion VARCHAR(30) NOT NULL,       -- 'COBRO','DEVOLUCION','ANULACION','DESEMBOLSO','CIERRE','RESERVA'
    referencia_temporal VARCHAR(50) NULL,      -- id generado en el cliente
    mensaje_error VARCHAR(200) NOT NULL,
    fecha_error DATETIME NOT NULL,
    resuelto TINYINT(1) NOT NULL DEFAULT 0,
    UNIQUE KEY uq_log_referencia (tipo_operacion, referencia_temporal),   -- [C10]
    FOREIGN KEY (id_usuario) REFERENCES USUARIO(id_usuario),
    FOREIGN KEY (id_sesion) REFERENCES SESION_CAJA(id_sesion)
);

-- =====================================================================
-- VISTAS DE APOYO (opcionales, simplifican el backend)
-- =====================================================================
-- HU-16 / RN-021: lo que se puede vender o reservar
CREATE OR REPLACE VIEW VW_STOCK_DISPONIBLE AS
SELECT s.id_stock,
       p.id_producto,
       p.codigo_producto,
       p.nombre_producto,
       s.cantidad_actual,
       s.cantidad_reservada,
       (s.cantidad_actual - s.cantidad_reservada) AS cantidad_disponible,
       s.stock_minimo
FROM STOCK s
JOIN PRODUCTOS p ON p.id_producto = s.id_producto;

-- HU-10 / RN-010: efectivo esperado por sesion de caja
CREATE OR REPLACE VIEW VW_EFECTIVO_ESPERADO AS
SELECT ses.id_sesion,
       ses.id_caja,
       ses.fondo_inicial,
       COALESCE(fx.efectivo_ventas,   0) AS efectivo_ventas,
       COALESCE(fx.efectivo_adelantos,0) AS efectivo_adelantos,
       COALESCE(ds.total_desembolsos, 0) AS total_desembolsos,
       (ses.fondo_inicial
        + COALESCE(fx.efectivo_ventas,   0)
        + COALESCE(fx.efectivo_adelantos,0)
        - COALESCE(ds.total_desembolsos, 0)) AS efectivo_esperado
FROM SESION_CAJA ses
LEFT JOIN (
    SELECT id_sesion,
           SUM(CASE WHEN origen = 'VENTA'   THEN monto ELSE 0 END) AS efectivo_ventas,
           SUM(CASE WHEN origen = 'RESERVA' THEN monto ELSE 0 END) AS efectivo_adelantos
    FROM (
        SELECT v.id_sesion AS id_sesion, p.monto AS monto, 'VENTA' AS origen
        FROM PAGO p
        JOIN VENTA v ON v.id_venta = p.id_venta
        JOIN TIPO_PAGO t ON t.id_metodo = p.id_metodo
        WHERE t.metodo_pago = 'Efectivo'
        UNION ALL
        SELECT r.id_sesion AS id_sesion, p.monto AS monto, 'RESERVA' AS origen
        FROM PAGO p
        JOIN RESERVA r ON r.id_reserva = p.id_reserva
        JOIN TIPO_PAGO t ON t.id_metodo = p.id_metodo
        WHERE t.metodo_pago = 'Efectivo'
    ) u
    GROUP BY id_sesion
) fx ON fx.id_sesion = ses.id_sesion
LEFT JOIN (
    SELECT id_sesion, SUM(monto) AS total_desembolsos
    FROM DESEMBOLSO GROUP BY id_sesion
) ds ON ds.id_sesion = ses.id_sesion;

-- =====================================================================
-- DATOS INICIALES
-- =====================================================================
INSERT INTO ESTADO(entidad, nombre_estado) VALUES
('USUARIO','Activo'),('USUARIO','Inactivo'),
('CLIENTE','Activo'),
('PRODUCTO','Activo'),('PRODUCTO','Inactivo'),
-- [C2] HU-18: toda campana nace 'Programada' y pasa a 'Activa' cuando inicia
('CAMPANA','Programada'),('CAMPANA','Activa'),('CAMPANA','Inactiva'),
('NEGOCIO','Activo'),
('CAJA','Activa'),('CAJA','Inactiva'),
('SESION_CAJA','Abierta'),('SESION_CAJA','Arqueada'),('SESION_CAJA','Cerrada'),
('VENTA','En espera'),('VENTA','Registrada'),('VENTA','Sin comprobante'),
('VENTA','Consolidada'),('VENTA','Devuelta'),('VENTA','Parcialmente devuelta'),
('VENTA','Anulada'),
('COMPROBANTE','Emitido'),('COMPROBANTE','Pendiente de envio'),('COMPROBANTE','Anulado'),
('DEVOLUCION','Autorizada'),
('RESERVA','Pendiente de entrega'),('RESERVA','Entrega parcial'),
('RESERVA','Entregada'),('RESERVA','Cancelada'),('RESERVA','Vencida');

INSERT INTO ROL(nombre_rol, descripcion) VALUES
('Vendedor','Ventas, reservas, arqueo y cierre de caja'),          -- RN-011
('Dueño','Todo lo del vendedor más Reportes, Promociones y autorización');  -- RN-011

-- SOLO Efectivo y Transferencia (sin Tarjeta/POS)
INSERT INTO TIPO_PAGO(metodo_pago) VALUES ('Efectivo'),('Transferencia');

-- HU-08: Boleta (03) y Ticket (12)
INSERT INTO TIPO_COMPROBANTE(codigo_sunat, nombre_tipo, prefijo_serie) VALUES
('03','Boleta de venta','B'),('12','Ticket','T');

-- Catalogo inicial de categorias (HU-03 / HU-14: filtro por categoria)
INSERT INTO CATEGORIA(nombre_categoria, descripcion) VALUES
('Cuadernos','Cuadernos de 50, 100, 120 y 180 hojas'),
('Papel y folios','Papel bond, folios, tarjetas y sobres'),
('Útiles de escritura','Lápices, plumas, marcadores, resaltadores y borradores'),
('Mochilas y loncheros','Mochilas escolares y accesorios'),
('Artículos de oficina','Tijeras, engrapadoras, folders y archivadores'),
('Libros y textos','Libros de lectura y textos escolares');

INSERT INTO CAJA(id_estado, numero_caja, nombre_caja)
SELECT id_estado, 1, 'Caja 1 (Dueño)' FROM ESTADO WHERE entidad='CAJA' AND nombre_estado='Activa';
INSERT INTO CAJA(id_estado, numero_caja, nombre_caja)
SELECT id_estado, 2, 'Caja 2' FROM ESTADO WHERE entidad='CAJA' AND nombre_estado='Activa';
INSERT INTO CAJA(id_estado, numero_caja, nombre_caja)
SELECT id_estado, 3, 'Caja 3' FROM ESTADO WHERE entidad='CAJA' AND nombre_estado='Activa';
INSERT INTO CAJA(id_estado, numero_caja, nombre_caja)
SELECT id_estado, 4, 'Caja 4' FROM ESTADO WHERE entidad='CAJA' AND nombre_estado='Activa';

-- [C8] HU-01: login por ID numerico fijo
--      ID 1 = Dueño   -> usuario 654321 / clave 654321
--      ID 2 = Vendedor-> usuario 123456 / clave 123456
--      RNF-05: contrasena guardada como hash con sal (SHA2-256 aqui;
--      en el backend real usar BCRYPT/ARGON2ID y comparar hashes).
INSERT INTO USUARIO(id_usuario, id_rol, id_estado, nombres, apellido_paterno, usuario, contrasena) VALUES
(1, 2, 1, 'Rosita', 'Ramírez', '654321', SHA2(CONCAT('salt_rosita_', '654321'), 256)),
(2, 1, 1, 'Carlos', 'López',   '123456', SHA2(CONCAT('salt_rosita_', '123456'), 256));

-- Ejemplo de negocio (reemplaza RUC/dirección por los reales)
INSERT INTO NEGOCIO(id_estado, ruc, razon_social, nombre_comercial, direccion_fiscal, categoria_nrus, tipo_comprobante_defecto)
SELECT id_estado, '20601234567', 'Libreria Bazar Rosita E.I.R.L.', 'Librería Bazar Rosita',
       'Jr. Los Rosales 123 - Cusco', 1, '03'
FROM ESTADO WHERE entidad='NEGOCIO' AND nombre_estado='Activo';

-- =====================================================================
-- TRIGGERS
-- =====================================================================
-- [C7] Anulacion (HU-19 / RN-020): mismo dia y con la caja todavia
--      ABierta (sin arquear y sin cerrar).
DELIMITER $$
CREATE TRIGGER trg_anulacion_mismo_dia
BEFORE INSERT ON DEVOLUCION
FOR EACH ROW
BEGIN
    DECLARE v_fecha_venta DATE;
    DECLARE v_estado_sesion VARCHAR(30);

    IF NEW.tipo_operacion = 'ANULACION' THEN

        IF NEW.id_venta IS NULL THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'La anulación debe estar asociada a una venta.';
        END IF;

        SELECT DATE(fecha_venta) INTO v_fecha_venta
        FROM VENTA WHERE id_venta = NEW.id_venta;
        IF v_fecha_venta <> CURDATE() THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Solo se puede anular una venta del mismo día.';
        END IF;

        SELECT e.nombre_estado INTO v_estado_sesion
        FROM SESION_CAJA s JOIN ESTADO e ON e.id_estado = s.id_estado
        WHERE s.id_sesion = NEW.id_sesion;

        IF v_estado_sesion IN ('Cerrada','Arqueada') THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'La caja de esa venta ya fue arqueada o cerrada; no se puede anular.';
        END IF;

    END IF;
END$$
DELIMITER ;

-- [C10] Integridad de anulacion: una venta no puede tener dos anulaciones activas
DELIMITER $$
CREATE TRIGGER trg_venta_unica_anulacion
BEFORE INSERT ON DEVOLUCION
FOR EACH ROW
BEGIN
    DECLARE v_existe INT;
    IF NEW.tipo_operacion = 'ANULACION' THEN
        SELECT COUNT(*) INTO v_existe
        FROM DEVOLUCION
        WHERE id_venta = NEW.id_venta AND tipo_operacion = 'ANULACION';
        IF v_existe > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Esta venta ya fue anulada anteriormente.';
        END IF;
    END IF;
END$$
DELIMITER ;

-- =====================================================================
-- VERIFICACION RAPIDA (opcional, bórrala en producción)
-- =====================================================================
-- SELECT 'ESTADO' t, COUNT(*) n FROM ESTADO
-- UNION ALL SELECT 'ROL', COUNT(*) FROM ROL
-- UNION ALL SELECT 'USUARIO', COUNT(*) FROM USUARIO
-- UNION ALL SELECT 'CAJA', COUNT(*) FROM CAJA
-- UNION ALL SELECT 'TIPO_PAGO', COUNT(*) FROM TIPO_PAGO
-- UNION ALL SELECT 'TIPO_COMPROBANTE', COUNT(*) FROM TIPO_COMPROBANTE;
