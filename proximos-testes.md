# Próximos testes

Ideias que apareceram na pesquisa e não foram testadas. Nenhuma tem resultado medido. Os ganhos descritos são hipóteses.

## 1. Índice em `lower(email)`

- **Fonte:** [PostgreSQL 16, 11.7 Indexes on Expressions](https://www.postgresql.org/docs/16/indexes-expressional.html). A ideia também foi sugerida pelo Gemini e pelo ChatGPT.
- **O que ganharia:** a rota `GET /clientes?email=` (15% da carga, mediana de ~1,1 s na mudança 08) filtra por `lower(email)`, sem índice. Provavelmente lê os 100 mil clientes a cada chamada.
- **Como testaria:** salvar o `EXPLAIN ANALYZE` da consulta em `diagnostico/`. Depois, `CREATE INDEX ... ON clientes (lower(email))` num `banco/08-...sql`, recriar o banco, verificar o contrato e medir 3 vezes.
- **O que precisaria:** só tempo (~15 min). Não muda o código.

## 2. Índice trigram (`pg_trgm`) para a busca de produtos

- **Fonte:** [PostgreSQL 16, pg_trgm](https://www.postgresql.org/docs/16/pgtrgm.html): os índices trigram "support index searches for LIKE and ILIKE", e a busca "need not be left-anchored".
- **O que ganharia:** `GET /produtos/busca` (15% da carga) usa `ILIKE '%termo%'`. Como são só 20 mil produtos e o `ORDER BY nome LIMIT 20` continua exigindo ordenação, o ganho é incerto.
- **Como testaria:** `CREATE EXTENSION pg_trgm` e um índice GIN `gin_trgm_ops` em `produtos(nome)`. Rodar `EXPLAIN` com os termos da carga e depois medir.
- **O que precisaria:** conferir os termos sorteados em `carga/teste-carga.js`. Termos sem trigramas suficientes viram leitura do índice inteiro.

## 3. Pool de conexões menor

- **Fonte:** [Percona, Scaling PostgreSQL with PgBouncer](https://www.percona.com/blog/scaling-postgresql-with-pgbouncer-you-may-need-a-connection-pooler-sooner-than-you-expect/): um pool do tamanho do número de CPUs rendeu quase o mesmo que um maior. Veja também [node-postgres, Pool](https://node-postgres.com/apis/pool) (`max`, padrão 10).
- **O que ganharia:** o banco tem 1 CPU, e o pool tem 10 conexões. Um pool de 2 a 4 conexões pode reduzir a disputa por CPU, mas também pode criar fila na API.
- **Como testaria:** `new Pool({ ...config, max: 4 })`, medir 3 vezes. Depois testar `max: 2`.
- **O que precisaria:** ~30 min para os dois tamanhos.

## 4. Desligar o paralelismo de consultas

- **Fonte:** [PostgreSQL 16, Resource Consumption](https://www.postgresql.org/docs/16/runtime-config-resource.html): `max_parallel_workers_per_gather` tem padrão 2, e "setting this value to 0 disables parallel query execution".
- **O que ganharia:** os planos salvos em `diagnostico/` mostram 3 processos em paralelo num banco limitado a 1 CPU. Sem paralelismo, pode haver menos disputa. Também pode haver regressão.
- **Como testaria:** `-c max_parallel_workers_per_gather=0` no `command` do serviço `banco` e medir 3 vezes.
- **O que precisaria:** ~15 min.

## 5. Estratégia de atualização da *materialized view*

- **Fontes:** [PostgreSQL 16, REFRESH MATERIALIZED VIEW](https://www.postgresql.org/docs/16/sql-refreshmaterializedview.html) e [Bloomberg, PostgresConf 2026](https://postgresconf.org/conferences/postgresconf_2026/program/proposals/materialized-view-case-studies-performance-shortcut-or-operational-trap).
- **O que ganharia:** tornaria a mudança 07 válida numa loja real, onde os dados mudam.
- **Como testaria:** um teste de carga com escrita (pedidos novos) e `REFRESH MATERIALIZED VIEW CONCURRENTLY` periódico (o índice UNIQUE já existe). Medir o custo do refresh e o atraso aceitável no ranking.
- **O que precisaria:** uma carga com escrita, que o desafio não tem, e uma definição de negócio sobre o atraso aceitável.

## 6. Custo dos índices nas escritas

- **Fonte:** [PayFit, Of PostgreSQL, Indexes, and Foreign Keys](https://backstage.payfit.com/of-postgresql-indexes-and-foreign-keys): escritas de 1% a 6% mais lentas com índice.
- **O que ganharia:** saber o custo real dos 4 índices novos em inserções e atualizações. Isso é o limite principal da solução.
- **Como testaria:** medir inserções de pedidos com itens antes e depois dos índices, com `pg_relation_size` para o espaço.
- **O que precisaria:** uma carga de escrita.

## 7. Paginação por cursor (*keyset*)

- **Fonte:** [Markus Winand, Use The Index, Luke: Indexed ORDER BY](https://use-the-index-luke.com/sql/sorting-grouping/indexed-order-by) (sobre a ordem do índice).
- **O que ganharia:** páginas profundas (`OFFSET` de até ~20 mil) sem descartar linhas.
- **Por que não testei:** muda os parâmetros da rota `/pedidos` e quebra o contrato. Só faria sentido numa nova versão da API.

## 8. Mais execuções e outra máquina

- **O que ganharia:** confirmar se as mudanças 03, 05 e 06 têm efeito no sistema ou se a diferença é ruído (a variação entre execuções passou de 20%).
- **Como testaria:** 5 a 10 execuções por versão, numa máquina Linux sem WSL.
- **O que precisaria:** tempo de máquina (~2 min por execução).

## 9. Reduzir a CPU da API ou os recursos do banco

- **O que ganharia:** custo menor.
- **Por que não agora:** na mudança 08, a API usa ~75% do limite de CPU (0,5) e o banco usa ~463 de 512 MiB. Cortar esses limites provavelmente custaria desempenho. Só faria sentido depois dos testes 1 a 4, se eles liberarem recursos.
