'use strict';

const fs = require('fs');
const path = require('path');

const catalogPath = path.join(__dirname, '..', 'Shared', 'providers.json');
const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
const providers = new Map(catalog.providers.map((provider) => [provider.id, provider]));

function requireProvider(id) {
  const provider = providers.get(id);
  if (!provider) throw new Error(`Unknown provider: ${id}`);
  return provider;
}

module.exports = {
  bridgePort: catalog.bridgePort,
  providers,
  requireProvider,
};
