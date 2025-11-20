// src/app.js
require('dotenv').config();
const express = require('express');
const { Pool } = require('pg');

const PORT = process.env.PORT || 14127;

const pool = new Pool({
    host: process.env.DATABASE_HOST || 'postgres',
    port: process.env.DATABASE_PORT || 5432,
    database: process.env.DATABASE_NAME || 'viavds',
    user: process.env.DATABASE_USER || 'viavds',
    password: process.env.DATABASE_PASS || 'viavds_pass',
});

const app = express();
app.use(express.json({ limit: process.env.MAX_PAYLOAD_SIZE || '5mb' }));
app.use(express.urlencoded({ extended: true }));

app.get('/health', (req, res) => res.json({ ok: true }));

app.all('*', async (req, res) => {
    try {
        const now = new Date().toISOString();
        const payload = JSON.stringify({
            headers: req.headers,
            method: req.method,
            url: req.originalUrl,
            body: req.body,
        });

        await pool.query(
            `INSERT INTO webhooks_raw(received_at, method, path, headers, body, raw_payload, status)
       VALUES ($1,$2,$3,$4,$5,$6,$7)`,
            [now, req.method, req.path, JSON.stringify(req.headers), JSON.stringify(req.body), payload, 'new']
        );

        // по умолчанию — вернуть 200
        res.status(200).json({ status: 'received' });
    } catch (err) {
        console.error(err);
        res.status(500).json({ error: 'db error' });
    }
});

app.listen(PORT, () => {
    console.log(`viavds dev server listening on ${PORT}`);
});
