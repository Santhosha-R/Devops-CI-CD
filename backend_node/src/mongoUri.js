// Builds the MongoDB connection URI from the mongo config. Kept pure (no I/O) so it is
// unit-testable without a running database — this is what the coverage report exercises.
function buildMongoUri(m) {
  return (
    'mongodb://' +
    encodeURIComponent(m.user) + ':' + encodeURIComponent(m.password) +
    '@' + m.host + ':' + m.port +
    '/' + m.dbName +
    '?authSource=' + m.authSource + '&retryWrites=true&w=majority'
  );
}

module.exports = { buildMongoUri };
