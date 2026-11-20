-- Mudança 02: índice na chave estrangeira pedidos.cliente_id
--
-- Diagnóstico: diagnostico/03-explain-pedidos-por-cliente.txt mostra um Parallel Seq Scan
-- em pedidos (~500 mil linhas lidas para achar 5) na consulta da rota
-- GET /clientes/:id/pedidos (api/src/rotas.js:70).
-- Mesma causa da mudança 01: o PostgreSQL não indexa chave estrangeira automaticamente.
CREATE INDEX pedidos_cliente_id_idx ON pedidos (cliente_id);
