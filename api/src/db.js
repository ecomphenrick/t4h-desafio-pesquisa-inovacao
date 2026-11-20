const { Pool } = require('pg');

const config = {
  host: process.env.DB_HOST || 'localhost',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'loja',
  database: process.env.DB_NAME || 'loja',
};

// Pool de conexões reaproveitadas, em vez de abrir e fechar uma conexão por consulta.
// Tamanho máximo: o padrão do node-postgres (10).
const pool = new Pool(config);

// Erro numa conexão ociosa do pool não deve derrubar a API.
pool.on('error', (erro) => {
  console.error('erro em conexão ociosa do pool', erro);
});

async function consultar(sql, parametros = []) {
  const resultado = await pool.query(sql, parametros);
  return resultado.rows;
}

module.exports = { consultar };
