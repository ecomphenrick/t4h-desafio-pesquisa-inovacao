-- Mudança 06: índice em pedidos(criado_em), usado pela rota GET /relatorios/vendas-por-dia
--
-- Diagnóstico: diagnostico/07-explain-vendas-por-dia.txt mostra um Parallel Seq Scan nos ~500 mil pedidos
-- para achar ~4,3 mil de um período de 7 dias, porque o filtro criado_em::date aplica a conversão em cada linha.
-- Junto com este índice, a rota passa a filtrar por intervalo (criado_em >= início AND criado_em < fim + 1 dia).
-- Fontes: PostgreSQL 16 Docs, 11.2.1 B-Tree; Markus Winand, Use The Index, Luke: Date and time conditions.
CREATE INDEX pedidos_criado_em_idx ON pedidos (criado_em);
