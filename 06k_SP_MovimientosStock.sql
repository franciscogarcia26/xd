bash

cat > /home/claude/tpi/06k_SP_MovimientosStock.sql << 'ENDSQL'
USE BD2_TPI_TIENDA_INDUMENTARIA;
GO

-- ============================================================
-- #10 - Registrar movimientos de stock por entradas, salidas
--       o ajustes manuales
-- ============================================================

-- sp_registrarMovimientoStock:
-- Permite registrar manualmente un movimiento de stock
-- (entrada, salida o ajuste) sobre un producto, actualizando
-- el StockActual en consecuencia.
-- Los movimientos vinculados a compras/ventas son generados
-- automáticamente por los triggers correspondientes.
-- Este SP está orientado a ajustes manuales y correcciones.

CREATE PROCEDURE sp_registrarMovimientoStock
    @IdProducto            INT,
    @IdTipoMovimientoStock INT,
    @IdEmpleado            INT,
    @Cantidad              INT,
    @Motivo                VARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @StockActual     INT;
    DECLARE @NombreTipo      VARCHAR(50);
    DECLARE @StockResultante INT;

    -- Validaciones básicas de parámetros
    IF @IdProducto IS NULL OR @IdProducto <= 0
    BEGIN
        RAISERROR('El id de producto es inválido', 16, 1);
        RETURN;
    END

    IF @IdTipoMovimientoStock IS NULL OR @IdTipoMovimientoStock <= 0
    BEGIN
        RAISERROR('El tipo de movimiento es inválido', 16, 1);
        RETURN;
    END

    IF @IdEmpleado IS NULL OR @IdEmpleado <= 0
    BEGIN
        RAISERROR('El id de empleado es inválido', 16, 1);
        RETURN;
    END

    IF @Cantidad IS NULL OR @Cantidad = 0
    BEGIN
        RAISERROR('La cantidad no puede ser cero ni nula', 16, 1);
        RETURN;
    END

    -- Validar que el producto exista y esté activo
    IF NOT EXISTS (
        SELECT 1 FROM Productos WHERE IdProducto = @IdProducto
    )
    BEGIN
        RAISERROR('No existe un producto con ese id', 16, 1);
        RETURN;
    END

    IF EXISTS (
        SELECT 1 FROM Productos WHERE IdProducto = @IdProducto AND Activo = 0
    )
    BEGIN
        RAISERROR('El producto no está activo', 16, 1);
        RETURN;
    END

    -- Validar que el tipo de movimiento exista
    IF NOT EXISTS (
        SELECT 1 FROM TiposMovimientoStock WHERE IdTipoMovimientoStock = @IdTipoMovimientoStock
    )
    BEGIN
        RAISERROR('No existe un tipo de movimiento con ese id', 16, 1);
        RETURN;
    END

    -- Validar que el empleado exista y esté activo
    IF NOT EXISTS (
        SELECT 1 FROM Empleados WHERE IdEmpleado = @IdEmpleado
    )
    BEGIN
        RAISERROR('No existe un empleado con ese id', 16, 1);
        RETURN;
    END

    IF EXISTS (
        SELECT 1 FROM Empleados WHERE IdEmpleado = @IdEmpleado AND Activo = 0
    )
    BEGIN
        RAISERROR('El empleado no está activo', 16, 1);
        RETURN;
    END

    -- Bloquear los tipos reservados para operaciones automáticas
    -- (Ingreso por compra / Egreso por venta).
    -- Esos movimientos los generan los triggers; este SP es solo
    -- para ajustes manuales y correcciones.
    SELECT @NombreTipo = UPPER(Nombre)
    FROM TiposMovimientoStock
    WHERE IdTipoMovimientoStock = @IdTipoMovimientoStock;

    IF @NombreTipo IN ('INGRESO POR COMPRA', 'EGRESO POR VENTA')
    BEGIN
        RAISERROR('Ese tipo de movimiento es gestionado automáticamente por el sistema. Use un tipo de ajuste manual.', 16, 1);
        RETURN;
    END

    -- Obtener el stock actual del producto
    SELECT @StockActual = StockActual
    FROM Productos
    WHERE IdProducto = @IdProducto;

    -- Calcular el stock resultante.
    -- Cantidad positiva = entrada; negativa = salida.
    SET @StockResultante = @StockActual + @Cantidad;

    -- Validar que el stock no quede negativo
    IF @StockResultante < 0
    BEGIN
        RAISERROR('Stock insuficiente para aplicar el ajuste solicitado', 16, 1);
        RETURN;
    END

    -- Todo validado: registrar el movimiento y actualizar el stock
    BEGIN TRY
        BEGIN TRANSACTION;

            INSERT INTO MovimientosStock (
                IdProducto,
                IdTipoMovimientoStock,
                IdEmpleado,
                IdCompra,
                IdVenta,
                FechaMovimiento,
                Cantidad,
                Motivo
            )
            VALUES (
                @IdProducto,
                @IdTipoMovimientoStock,
                @IdEmpleado,
                NULL,
                NULL,
                SYSDATETIME(),
                @Cantidad,
                NULLIF(LTRIM(RTRIM(@Motivo)), '')
            );

            UPDATE Productos
            SET StockActual = @StockResultante
            WHERE IdProducto = @IdProducto;

        COMMIT;
        PRINT CONCAT(
            'Movimiento registrado. Stock anterior: ', @StockActual,
            ' | Ajuste: ', @Cantidad,
            ' | Stock nuevo: ', @StockResultante
        );
    END TRY
    BEGIN CATCH
        ROLLBACK;
        THROW;
    END CATCH;
END;
GO


-- ============================================================
-- Trigger: trg_registrarMovimientoStockCompra
-- Registra automáticamente en MovimientosStock cuando una
-- compra pasa a CONFIRMADA (entrada de stock).
-- ============================================================

CREATE TRIGGER trg_registrarMovimientoStockCompra
ON Compras
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @IdTipoIngreso INT;

    SELECT @IdTipoIngreso = IdTipoMovimientoStock
    FROM TiposMovimientoStock
    WHERE UPPER(Nombre) = 'INGRESO POR COMPRA';

    IF @IdTipoIngreso IS NULL
        RETURN;

    INSERT INTO MovimientosStock (
        IdProducto,
        IdTipoMovimientoStock,
        IdEmpleado,
        IdCompra,
        IdVenta,
        FechaMovimiento,
        Cantidad,
        Motivo
    )
    SELECT
        dc.IdProducto,
        @IdTipoIngreso,
        i.IdEmpleado,
        i.IdCompra,
        NULL,
        SYSDATETIME(),
        dc.Cantidad,
        CONCAT('Ingreso automático por confirmación de compra #', i.IdCompra)
    FROM inserted i
    INNER JOIN deleted d           ON d.IdCompra        = i.IdCompra
    INNER JOIN EstadosCompra ecAnt ON ecAnt.IdEstadoCompra = d.IdEstadoCompra
    INNER JOIN EstadosCompra ecNvo ON ecNvo.IdEstadoCompra = i.IdEstadoCompra
    INNER JOIN DetalleCompras dc   ON dc.IdCompra        = i.IdCompra
    WHERE i.IdEstadoCompra <> d.IdEstadoCompra
      AND UPPER(ecAnt.Nombre) <> 'CONFIRMADA'
      AND UPPER(ecNvo.Nombre)  = 'CONFIRMADA';
END;
GO


-- ============================================================
-- Trigger: trg_registrarMovimientoStockVenta
-- Registra automáticamente en MovimientosStock cuando una
-- venta pasa a CONFIRMADA (salida de stock).
-- ============================================================

CREATE TRIGGER trg_registrarMovimientoStockVenta
ON Ventas
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @IdTipoEgreso INT;

    SELECT @IdTipoEgreso = IdTipoMovimientoStock
    FROM TiposMovimientoStock
    WHERE UPPER(Nombre) = 'EGRESO POR VENTA';

    IF @IdTipoEgreso IS NULL
        RETURN;

    INSERT INTO MovimientosStock (
        IdProducto,
        IdTipoMovimientoStock,
        IdEmpleado,
        IdCompra,
        IdVenta,
        FechaMovimiento,
        Cantidad,
        Motivo
    )
    SELECT
        dv.IdProducto,
        @IdTipoEgreso,
        i.IdEmpleado,
        NULL,
        i.IdVenta,
        SYSDATETIME(),
        dv.Cantidad * -1,   -- negativo: es una salida
        CONCAT('Egreso automático por confirmación de venta #', i.IdVenta)
    FROM inserted i
    INNER JOIN deleted d           ON d.IdVenta          = i.IdVenta
    INNER JOIN EstadosVenta evAnt  ON evAnt.IdEstadoVenta  = d.IdEstadoVenta
    INNER JOIN EstadosVenta evNvo  ON evNvo.IdEstadoVenta  = i.IdEstadoVenta
    INNER JOIN DetalleVentas dv    ON dv.IdVenta           = i.IdVenta
    WHERE i.IdEstadoVenta <> d.IdEstadoVenta
      AND UPPER(evAnt.Nombre) <> 'CONFIRMADA'
      AND UPPER(evNvo.Nombre)  = 'CONFIRMADA';
END;
GO


-- ============================================================
-- Ejemplos de uso
-- ============================================================

/*
-- Ajuste positivo manual (ej: corrección de inventario físico)
EXEC sp_registrarMovimientoStock
    @IdProducto            = 1,
    @IdTipoMovimientoStock = 3,   -- Ajuste manual
    @IdEmpleado            = 1,
    @Cantidad              = 5,
    @Motivo                = 'Corrección de diferencia en inventario físico';

-- Ajuste negativo manual (ej: producto dañado)
EXEC sp_registrarMovimientoStock
    @IdProducto            = 2,
    @IdTipoMovimientoStock = 5,   -- Ajuste negativo
    @IdEmpleado            = 1,
    @Cantidad              = -2,
    @Motivo                = 'Baja por producto dañado';

-- Consultar historial de movimientos de un producto
SELECT
    ms.IdMovimientoStock,
    p.Nombre           AS Producto,
    tms.Nombre         AS TipoMovimiento,
    CONCAT(e.Nombre, ' ', e.Apellido) AS Empleado,
    ms.IdCompra,
    ms.IdVenta,
    ms.FechaMovimiento,
    ms.Cantidad,
    ms.Motivo
FROM MovimientosStock ms
INNER JOIN Productos            p   ON p.IdProducto            = ms.IdProducto
INNER JOIN TiposMovimientoStock tms ON tms.IdTipoMovimientoStock = ms.IdTipoMovimientoStock
LEFT  JOIN Empleados            e   ON e.IdEmpleado             = ms.IdEmpleado
WHERE ms.IdProducto = 1
ORDER BY ms.FechaMovimiento DESC;
*/
ENDSQL
Salida

exit code 0
