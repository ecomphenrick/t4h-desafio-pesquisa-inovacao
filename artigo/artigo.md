# Uma API 10 vezes mais rápida e com menos memória: o gargalo era o trabalho pedido ao banco, não a falta de hardware

## 1. Resumo

A API de uma loja fictícia (Node.js + PostgreSQL, em Docker) atendia 2,06 requisições por segundo, com p95 de 34,6 s, e o banco ficava com a CPU em 98% o tempo todo. Em vez de aumentar recursos, reduzi o trabalho que cada requisição pede ao banco, em sete mudanças medidas uma a uma: índices em chaves estrangeiras e na ordenação, pool de conexões, fim do N+1, filtro de data que aproveita índice e uma *materialized view* para o relatório mais pesado. Resultado: 21,0 requisições por segundo (10,2x) e p95 de 2,3 s (−93%), com as mesmas respostas. Com o trabalho reduzido, cortei pela metade o limite de memória da API (256 → 128 MB) sem perder desempenho: o sistema ficou mais rápido e mais barato.

## 2. Contexto e diagnóstico

A aplicação tem sete rotas de leitura sobre 100 mil clientes, 500 mil pedidos e 1,5 milhão de itens. O "custo" são os limites dos containers: 0,5 CPU e 256 MB para a API, 1 CPU e 512 MB para o banco. Medi tudo com o script de carga do desafio (k6, 20 usuários, 60 s), três vezes por versão, comparando medianas.

Na linha de base, o banco ficou com 98,4% de CPU e a API com 9,2% ([recursos.txt](../resultados/20261119-091036-00-linha-de-base/recursos.txt)): a API passava o tempo esperando o banco. Até a busca por chave primária levava 552 ms, o que indica fila, não lentidão da própria consulta. Para escolher o que atacar, multipliquei a mediana de cada rota pelo seu peso na carga; `GET /clientes/:id/pedidos` respondia por cerca de 60% do tempo de espera.

A partir daí, cada rota foi investigada com `EXPLAIN ANALYZE`, com as saídas salvas em [diagnostico/](../diagnostico/):

- O banco só tinha índices nas chaves primárias ([02](../diagnostico/02-indices-existentes.txt)). Buscar os itens de um pedido lia 1,5 milhão de linhas para achar 2 ([01](../diagnostico/01-explain-itens-por-pedido.txt)).
- A listagem por status ordenava 300 mil pedidos em disco para devolver 20 ([04](../diagnostico/04-explain-pedidos-por-status.txt)).
- O relatório de vendas convertia a data de cada linha (`criado_em::date`) e lia os 500 mil pedidos ([07](../diagnostico/07-explain-vendas-por-dia.txt)).
- No código, a API abria uma conexão nova para cada consulta e, na rota de pedidos, fazia uma consulta por pedido e outra por item.

**Hipóteses de causa:** (1) chaves estrangeiras sem índice forçam leitura de tabelas inteiras; (2) ordenações e filtros que não aproveitam índice; (3) uma conexão nova por consulta gasta CPU do banco criando processos; (4) o padrão N+1 multiplica idas e voltas ao banco; (5) um relatório recalcula do zero, a cada chamada, um resultado que não muda.

## 3. Estado da arte

### Índices: chaves estrangeiras, ordenação e datas

O PostgreSQL cria índice automaticamente para chave primária, mas "a declaração de uma chave estrangeira não cria automaticamente um índice nas colunas que referenciam" [1]. O GitLab tornou esses índices obrigatórios depois de incidentes com timeouts [2], e a PayFit mediu leituras ~22% mais rápidas com escritas 1% a 6% mais lentas [3]. A Percona alerta para não indexar toda chave estrangeira por reflexo [4]. Para ordenação, um índice B-tree na ordem do `ORDER BY` permite que, com `LIMIT`, "as primeiras n linhas sejam obtidas diretamente" [5]; Jovanović aplica a regra "colunas de igualdade primeiro, depois a de ordenação" [6]. Para datas, Winand mostra que funções sobre a coluna impedem o índice e recomenda "uma condição de intervalo explícita" [7].

### Conexões

O PostgreSQL cria um processo para cada conexão [8], e a documentação do node-postgres recomenda pool para aplicações web, citando um handshake de 20 a 30 ms [9]. A Command Prompt mediu 8 vezes mais transações com pool, usando menos CPU [10]. Em contraponto, a Percona mediu que um pool externo pode ser 2,5x pior com poucos clientes [11].

### Consultas em lote (N+1)

Yang et al. (ICSE 2018) estudaram 12 aplicações reais, encontraram o N+1 ainda frequente e, corrigindo 64 problemas, obtiveram "aceleração mediana de 2x" [12]. Os mesmos autores alertam que carregar tudo de uma vez pode gerar pressão de memória.

### Pré-agregação

Uma *materialized view* guarda o resultado de uma consulta; o acesso "costuma ser muito mais rápido", mas "o dado nem sempre está atualizado" [13]. A Bloomberg relata custos ocultos: atualizações longas e fragilidade com o crescimento dos dados [14].

## 4. Alternativas consideradas

| Alternativa | Custo | Desempenho | Risco | Esforço |
|---|---|---|---|---|
| Aumentar a CPU do banco (1 → 2) | +1 CPU (+67% no total) | Mais vazão, sem atacar a causa | Contraria o objetivo "mais barato" | Baixo |
| Índices guiados pelo `EXPLAIN` | Disco; escritas mais lentas | Alto nas rotas com leitura sequencial | Baixo para o contrato | Baixo |
| Pool de conexões na API | Nenhum recurso novo | Alto em todas as rotas | Baixo | Baixo |
| PgBouncer (pool externo) | Serviço novo | Parecido, com um salto a mais | 2,5x pior com poucos clientes [11] | Médio |
| Reescrever consultas (N+1, filtro de data) | Nenhum | Médio a alto na rota alvo | Médio: ordem e tipos das respostas | Médio |
| *Materialized view* / cache | Disco e memória | Muito alto no relatório | Dado desatualizado numa loja real | Médio |
| Paginação por cursor (*keyset*) | Nenhum | Alto em páginas profundas | Quebra o contrato | Médio |

Escolhi as opções que reduzem trabalho sem recurso novo e descartei as que mudariam o contrato ou o custo.

## 5. Solução escolhida e por quê

Escolhi atacar a quantidade de trabalho por requisição, guiado por evidência: primeiro o `EXPLAIN ANALYZE`, depois a mudança mínima que elimina o trabalho desnecessário. O argumento é simples: com o banco em 98% de CPU, cada segundo de CPU economizado vira capacidade, sem custo de infraestrutura. Aumentar a CPU do banco foi descartado porque esconderia a causa e contrariaria o objetivo de custo. O PgBouncer e o Redis foram descartados porque acrescentam serviços. A paginação por cursor foi descartada porque mudaria os parâmetros da rota.

A *materialized view* é a escolha mais discutível. No teste, os dados não mudam, então ela devolve exatamente o mesmo resultado. Numa loja real, ela só vale se o negócio aceitar um ranking atualizado periodicamente (ver seção 7).

## 6. Experimento e resultado

Medianas de três execuções por versão, calculadas por script a partir de `resultados/`. O "antes" de cada linha é a mudança anterior. CPU e memória são as médias do banco, salvo indicação.

| Mudança | Hipótese | p95 antes → depois | req/s antes → depois | CPU/memória (banco) | Pastas de resultados | Conclusão |
|---|---|---|---|---|---|---|
| 00-linha-de-base | — | 34.613 ms | 2,06 | 98,4% / 385 MiB; API 9,2% | [1](../resultados/20261119-091036-00-linha-de-base/) [2](../resultados/20261119-091229-00-linha-de-base/) [3](../resultados/20261119-091458-00-linha-de-base/) | Banco saturado |
| 01-indice-itens-pedido | FK sem índice lê 1,5 mi linhas | 34.613 → 19.640 | 2,06 → 2,76 | 97,2% / 389 MiB | [1](../resultados/20261119-224122-01-indice-itens-pedido/) [2](../resultados/20261119-224311-01-indice-itens-pedido/) [3](../resultados/20261119-224501-01-indice-itens-pedido/) | Ganho; erros de 0,5% em top-produtos |
| 02-indice-pedidos-cliente | Mesma causa, tabela de pedidos | 19.640 → 16.886 | 2,76 → 3,78 | 98,3% / 388 MiB | [1](../resultados/20261119-231834-02-indice-pedidos-cliente/) [2](../resultados/20261119-232016-02-indice-pedidos-cliente/) [3](../resultados/20261119-232200-02-indice-pedidos-cliente/) | Ganho |
| 03-indice-pedidos-status | Ordenação em disco | 16.886 → 19.563 | 3,78 → 3,61 | 97,3% / 424 MiB | [1](../resultados/20261120-000617-03-indice-pedidos-status/) [2](../resultados/20261120-000805-03-indice-pedidos-status/) [3](../resultados/20261120-000954-03-indice-pedidos-status/) | **Sem ganho** no sistema; rota alvo −49% |
| 04-pool-conexoes | Conexão por consulta gasta CPU | 19.563 → 11.257 | 3,61 → 7,85 | 97,9% / 427 MiB | [1](../resultados/20261120-002417-04-pool-conexoes/) [2](../resultados/20261120-002550-04-pool-conexoes/) [3](../resultados/20261120-002731-04-pool-conexoes/) | Ganho em todas as rotas |
| 05-sem-n-mais-1 | ~22 consultas viram 3 | 11.257 → 6.448 | 7,85 → 8,09 | 98,1% / 423 MiB | [1](../resultados/20261120-112109-05-sem-n-mais-1/) [2](../resultados/20261120-112248-05-sem-n-mais-1/) [3](../resultados/20261120-112430-05-sem-n-mais-1/) | Rota alvo −56%; vazão igual; outras rotas pioraram |
| 06-vendas-intervalo-indice | `::date` impede índice | 6.448 → 6.079 | 8,09 → 8,43 | 96,9% / 405 MiB | [1](../resultados/20261120-114331-06-vendas-intervalo-indice/) [2](../resultados/20261120-114510-06-vendas-intervalo-indice/) [3](../resultados/20261120-114650-06-vendas-intervalo-indice/) | Rota alvo −32%; sistema dentro da variação |
| 07-mv-top-produtos | Relatório recalcula tudo | 6.079 → 2.107 | 8,43 → 20,00 | 92,4% / 458 MiB; API 37,6% | [1](../resultados/20261120-115430-07-mv-top-produtos/) [2](../resultados/20261120-115553-07-mv-top-produtos/) [3](../resultados/20261120-115717-07-mv-top-produtos/) | Maior ganho; todas as rotas melhoraram |
| 08-api-128mb | API usa ~42 de 256 MiB: memória sobrando | 2.107 → 2.284 | 20,00 → 21,00 | 88,8% / 463 MiB; API 36,4 MiB (máx. 58,9) de 128 | [1](../resultados/20261120-150152-08-api-128mb/) [2](../resultados/20261120-150317-08-api-128mb/) [3](../resultados/20261120-150442-08-api-128mb/) | Desempenho mantido (dentro da variação); memória reservada total 768 → 640 MiB (−16,7%) |

Três resultados contrariaram a expectativa. A mudança 03 deixou a rota alvo duas vezes mais rápida, mas não melhorou o sistema; a variação entre execuções (3,05 a 3,88 req/s) era maior que a diferença medida. Interpreto que o custo de abrir conexões, eliminado só na 04, escondia o efeito. A mudança 05 acelerou a rota de pedidos, mas não aumentou a vazão: depois dos índices, as consultas do N+1 já eram baratas, e o que pesava era a espera sequencial. As outras rotas pioraram, provavelmente porque a fila no banco saturado se redistribuiu. Por fim, a rota com só 2% da carga, top-produtos, era a que mais travava o banco: ao pré-agregá-la, todas as rotas ficaram mais rápidas e o banco saiu da saturação pela primeira vez.

## 7. Limites e testes futuros

- **Dado desatualizado.** A *materialized view* devolve o mesmo resultado porque os dados do teste são estáticos. Numa loja real, uma venda nova só entraria no ranking depois de um `REFRESH`, que recalcula tudo [13]. Isso mudaria o que a rota faz. Se o negócio exigir ranking em tempo real, a conclusão sobre a mudança 07 cai.
- **Escritas não medidas.** A carga só tem leituras. Os quatro índices novos nas tabelas deixam inserções e atualizações mais lentas, como mediu a PayFit [3], e eu não verifiquei quanto.
- **Recursos.** A memória da API tinha folga e foi reduzida pela metade. Já a CPU da API está em ~75% do limite e o banco usa ~463 de 512 MiB: cortar esses limites provavelmente custaria desempenho. Não testei.
- **Medição.** Foram só três execuções por versão, numa única máquina (Windows + WSL 2). Encontrei também um erro no script de medição: a coluna `cpu_max` compara números como texto ([06](../diagnostico/06-bug-cpu-max-medir.txt)). Por isso usei apenas a CPU média.
- **O que derrubaria a conclusão:** se, em outra máquina e com mais execuções, as vazões das mudanças 04 e 07 caíssem dentro da faixa das versões anteriores, os ganhos seriam ruído. Hoje, a pior execução de cada uma supera a melhor da versão anterior.

Ficaram como testes futuros, no [proximos-testes.md](../proximos-testes.md): índice em `lower(email)`, `pg_trgm` para a busca de produtos, pool menor, desligar o paralelismo de consultas num banco de 1 CPU, estratégia de atualização da view e redução da memória da API.

## 8. Referências

1. PostgreSQL Global Development Group. *PostgreSQL 16 Documentation, 5.4 Constraints*. https://www.postgresql.org/docs/16/ddl-constraints.html. Acesso em 19/11/2026.
2. GitLab. *Foreign keys and associations* (Development guidelines). https://docs.gitlab.com/development/database/foreign_keys/. Acesso em 19/11/2026.
3. Francoise, C. (PayFit). *Of PostgreSQL, Indexes, and Foreign Keys*, 27/01/2023. https://backstage.payfit.com/of-postgresql-indexes-and-foreign-keys. Acesso em 19/11/2026.
4. Batista, C. (Percona). *Should I Create an Index on Foreign Keys in PostgreSQL?*, 18/11/2021. https://www.percona.com/blog/should-i-create-an-index-on-foreign-keys-in-postgresql/. Acesso em 19/11/2026.
5. PostgreSQL Global Development Group. *PostgreSQL 16 Documentation, 11.4 Indexes and ORDER BY*. https://www.postgresql.org/docs/16/indexes-ordering.html. Acesso em 20/11/2026.
6. Jovanović, M. *From 17ms to 0.04ms: How to Design the Right SQL Index*, 22/08/2026. https://milanjovanovic.tech/blog/how-to-design-the-right-sql-index. Acesso em 20/11/2026.
7. Winand, M. *Use The Index, Luke: Date and time conditions*. https://use-the-index-luke.com/sql/where-clause/obfuscation/dates. Acesso em 20/11/2026.
8. PostgreSQL Global Development Group. *PostgreSQL 16 Documentation, 52.2 How Connections Are Established*. https://www.postgresql.org/docs/16/connect-estab.html. Acesso em 20/11/2026.
9. node-postgres. *Pooling*. https://node-postgres.com/features/pooling. Acesso em 20/11/2026.
10. Command Prompt. *Connection Initiation Overhead is Killing Your Web App*. https://www.commandprompt.com/blog/connection-initiation-overhead-pgbouncer/. Acesso em 20/11/2026.
11. Laudares Camargos, F. (Percona). *Scaling PostgreSQL with PgBouncer: You May Need a Connection Pooler Sooner Than You Expect*, 27/06/2018. https://www.percona.com/blog/scaling-postgresql-with-pgbouncer-you-may-need-a-connection-pooler-sooner-than-you-expect/. Acesso em 20/11/2026.
12. Yang, J.; Subramaniam, P.; Lu, S.; Yan, C.; Cheung, A. *How not to structure your database-backed web applications: a study of performance bugs in the wild*. ICSE 2018. https://doi.org/10.1145/3180155.3180194. Acesso em 20/11/2026.
13. PostgreSQL Global Development Group. *PostgreSQL 16 Documentation, 41.3 Materialized Views* e *REFRESH MATERIALIZED VIEW*. https://www.postgresql.org/docs/16/rules-materializedviews.html e https://www.postgresql.org/docs/16/sql-refreshmaterializedview.html. Acesso em 20/11/2026.
14. Law, Y. L.; Hong, C. (Bloomberg). *Materialized Views: Performance Shortcut or Operational Trap?* PostgresConf 2026. https://postgresconf.org/conferences/postgresconf_2026/program/proposals/materialized-view-case-studies-performance-shortcut-or-operational-trap. Acesso em 20/11/2026.

## 9. Uso de IA

Usei o Claude Code para ler o código, sugerir hipóteses, rodar os `EXPLAIN`, aplicar e medir as mudanças, buscar fontes e revisar o texto. Também consultei o Gemini e o ChatGPT para sugerir próximos caminhos. Verifiquei cada fonte abrindo o link (descartei as que não comprovavam o que se dizia delas) e calculei todos os números por script a partir das pastas de `resultados/`, conferindo-os contra os arquivos originais.
