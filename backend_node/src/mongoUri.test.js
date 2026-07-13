const { buildMongoUri } = require('./mongoUri');

describe('buildMongoUri', () => {
  const base = { user: 'admin', password: 'password', host: 'mongo-service', port: 27017, dbName: 'userdb', authSource: 'admin' };

  test('builds a full URI with auth source and options', () => {
    expect(buildMongoUri(base)).toBe(
      'mongodb://admin:password@mongo-service:27017/userdb?authSource=admin&retryWrites=true&w=majority'
    );
  });

  test('url-encodes special characters in the credentials', () => {
    const uri = buildMongoUri({ ...base, user: 'a/b', password: 'p@ss:w0rd' });
    expect(uri).toContain('a%2Fb');
    expect(uri).toContain('p%40ss%3Aw0rd');
  });

  test('uses the internal cluster DNS host verbatim', () => {
    const uri = buildMongoUri({ ...base, host: 'mongo-service.database.svc.cluster.local' });
    expect(uri).toContain('@mongo-service.database.svc.cluster.local:27017/');
  });
});
