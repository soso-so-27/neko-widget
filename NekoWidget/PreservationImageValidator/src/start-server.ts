import { createValidatorHTTPServer } from './http-server.js';

const port = Number(process.env.PORT ?? '8080');
if (process.env.JPEG_VALIDATOR_ENABLED !== 'YES' || !Number.isSafeInteger(port)
    || port < 1 || port > 65_535) throw new Error('validator configuration invalid');

createValidatorHTTPServer(process.env.JPEG_VALIDATOR_CALLER_SECRET ?? '')
  .listen(port, '0.0.0.0');
