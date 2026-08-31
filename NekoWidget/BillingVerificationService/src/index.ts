import { loadConfig } from "./config.js";
import { createBillingVerificationServer } from "./server.js";

const config = loadConfig();
const server = createBillingVerificationServer(config);
server.listen(config.port, "0.0.0.0");
