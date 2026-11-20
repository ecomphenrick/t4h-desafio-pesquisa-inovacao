-- Mudança 01: índice na chave estrangeira itens_pedido.pedido_id
--
-- Diagnóstico: diagnostico/01-explain-itens-por-pedido.txt mostra um Parallel Seq Scan
-- em itens_pedido (~1,5 milhão de linhas lidas para achar 2) na consulta da rota
-- GET /clientes/:id/pedidos (api/src/rotas.js:76).
-- O PostgreSQL não cria índice automaticamente em colunas de chave estrangeira
-- (documentação do PostgreSQL 16, seção 5.4.5).
CREATE INDEX itens_pedido_pedido_id_idx ON itens_pedido (pedido_id);
