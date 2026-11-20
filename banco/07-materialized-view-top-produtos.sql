-- Mudança 07: materialized view com o ranking de produtos por receita (rota GET /relatorios/top-produtos)
--
-- Antes, cada chamada da rota somava o 1,5 milhão de itens com JOIN em pedidos e produtos (mediana de ~16 s sob carga
-- na mudança 06). A view guarda o resultado já agregado; a rota só lê as primeiras linhas.
-- Os dados do teste não mudam, então a view criada junto com o banco é igual à consulta original.
-- Numa loja real seria preciso atualizar com REFRESH MATERIALIZED VIEW (CONCURRENTLY usa o índice UNIQUE abaixo).
-- Fontes: PostgreSQL 16 Docs, 41.3 Materialized Views e REFRESH MATERIALIZED VIEW.
CREATE MATERIALIZED VIEW top_produtos_mv AS
SELECT pr.id, pr.nome, pr.categoria,
       sum(i.quantidade) AS unidades,
       sum(i.quantidade * i.preco_unitario_centavos) AS receita_centavos
  FROM itens_pedido i
  JOIN pedidos p ON p.id = i.pedido_id
  JOIN produtos pr ON pr.id = i.produto_id
 WHERE p.status <> 'cancelado'
 GROUP BY pr.id, pr.nome, pr.categoria;

CREATE UNIQUE INDEX top_produtos_mv_id_idx ON top_produtos_mv (id);
CREATE INDEX top_produtos_mv_receita_idx ON top_produtos_mv (receita_centavos DESC, id);
