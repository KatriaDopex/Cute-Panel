"use strict";
// packages/core/src/api/ApiClient.ts
var __extends = (this && this.__extends) || (function () {
    var extendStatics = function (d, b) {
        extendStatics = Object.setPrototypeOf ||
            ({ __proto__: [] } instanceof Array && function (d, b) { d.__proto__ = b; }) ||
            function (d, b) { for (var p in b) if (Object.prototype.hasOwnProperty.call(b, p)) d[p] = b[p]; };
        return extendStatics(d, b);
    };
    return function (d, b) {
        if (typeof b !== "function" && b !== null)
            throw new TypeError("Class extends value " + String(b) + " is not a constructor or null");
        extendStatics(d, b);
        function __() { this.constructor = d; }
        d.prototype = b === null ? Object.create(b) : (__.prototype = b.prototype, new __());
    };
})();
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
var __generator = (this && this.__generator) || function (thisArg, body) {
    var _ = { label: 0, sent: function() { if (t[0] & 1) throw t[1]; return t[1]; }, trys: [], ops: [] }, f, y, t, g = Object.create((typeof Iterator === "function" ? Iterator : Object).prototype);
    return g.next = verb(0), g["throw"] = verb(1), g["return"] = verb(2), typeof Symbol === "function" && (g[Symbol.iterator] = function() { return this; }), g;
    function verb(n) { return function (v) { return step([n, v]); }; }
    function step(op) {
        if (f) throw new TypeError("Generator is already executing.");
        while (g && (g = 0, op[0] && (_ = 0)), _) try {
            if (f = 1, y && (t = op[0] & 2 ? y["return"] : op[0] ? y["throw"] || ((t = y["return"]) && t.call(y), 0) : y.next) && !(t = t.call(y, op[1])).done) return t;
            if (y = 0, t) op = [op[0] & 2, t.value];
            switch (op[0]) {
                case 0: case 1: t = op; break;
                case 4: _.label++; return { value: op[1], done: false };
                case 5: _.label++; y = op[1]; op = [0]; continue;
                case 7: op = _.ops.pop(); _.trys.pop(); continue;
                default:
                    if (!(t = _.trys, t = t.length > 0 && t[t.length - 1]) && (op[0] === 6 || op[0] === 2)) { _ = 0; continue; }
                    if (op[0] === 3 && (!t || (op[1] > t[0] && op[1] < t[3]))) { _.label = op[1]; break; }
                    if (op[0] === 6 && _.label < t[1]) { _.label = t[1]; t = op; break; }
                    if (t && _.label < t[2]) { _.label = t[2]; _.ops.push(op); break; }
                    if (t[2]) _.ops.pop();
                    _.trys.pop(); continue;
            }
            op = body.call(thisArg, _);
        } catch (e) { op = [6, e]; y = 0; } finally { f = t = 0; }
        if (op[0] & 5) throw op[1]; return { value: op[0] ? op[1] : void 0, done: true };
    }
};
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.ApiClient = exports.ApiClientError = void 0;
var axios_1 = __importDefault(require("axios"));
// Custom error class for API errors
var ApiClientError = /** @class */ (function (_super) {
    __extends(ApiClientError, _super);
    function ApiClientError(message, statusCode, errorCode, errorDetails) {
        var _this = _super.call(this, message) || this;
        _this.name = 'ApiClientError';
        _this.statusCode = statusCode;
        _this.errorCode = errorCode;
        _this.errorDetails = errorDetails;
        Object.setPrototypeOf(_this, ApiClientError.prototype);
        return _this;
    }
    return ApiClientError;
}(Error));
exports.ApiClientError = ApiClientError;
var ApiClient = /** @class */ (function () {
    function ApiClient(baseURL, apiKey) {
        var _this = this;
        this.apiKey = apiKey;
        this.axiosInstance = axios_1.default.create({
            baseURL: baseURL, // e.g., http://localhost:8052/api/v1
            headers: {
                'Content-Type': 'application/json',
            },
        });
        // Add a request interceptor to include the API key
        this.axiosInstance.interceptors.request.use(function (config) {
            if (_this.apiKey) {
                // Ensure headers object exists
                config.headers = config.headers || {};
                config.headers['X-API-Key'] = _this.apiKey;
            }
            return config;
        }, function (error) {
            return Promise.reject(error);
        });
    }
    ApiClient.prototype.handleApiError = function (error) {
        var _a;
        if (error.response) {
            var responseData = error.response.data;
            // Check if it's our standardized error format
            if (responseData && responseData.error && responseData.error.message) {
                var errDetail = responseData.error;
                throw new ApiClientError(errDetail.message, errDetail.status_code || error.response.status, errDetail.error_code, errDetail.details);
            }
            else {
                // Fallback for non-standard errors or network issues
                throw new ApiClientError(((_a = error.response.data) === null || _a === void 0 ? void 0 : _a.message) || error.message, error.response.status, 'UNKNOWN_CLIENT_ERROR', error.response.data);
            }
        }
        else if (error.request) {
            // The request was made but no response was received
            throw new ApiClientError('No response received from server', 503, 'NETWORK_ERROR', error.request);
        }
        else {
            // Something happened in setting up the request that triggered an Error
            throw new ApiClientError("Request setup error: ".concat(error.message), 500, 'REQUEST_SETUP_ERROR');
        }
    };
    ApiClient.prototype.get = function (path, config) {
        return __awaiter(this, void 0, void 0, function () {
            var response, error_1;
            return __generator(this, function (_a) {
                switch (_a.label) {
                    case 0:
                        _a.trys.push([0, 2, , 3]);
                        return [4 /*yield*/, this.axiosInstance.get(path, config)];
                    case 1:
                        response = _a.sent();
                        return [2 /*return*/, response.data];
                    case 2:
                        error_1 = _a.sent();
                        this.handleApiError(error_1);
                        return [3 /*break*/, 3];
                    case 3: return [2 /*return*/];
                }
            });
        });
    };
    ApiClient.prototype.post = function (path, data, config) {
        return __awaiter(this, void 0, void 0, function () {
            var response, error_2;
            return __generator(this, function (_a) {
                switch (_a.label) {
                    case 0:
                        _a.trys.push([0, 2, , 3]);
                        return [4 /*yield*/, this.axiosInstance.post(path, data, config)];
                    case 1:
                        response = _a.sent();
                        return [2 /*return*/, response.data];
                    case 2:
                        error_2 = _a.sent();
                        this.handleApiError(error_2);
                        return [3 /*break*/, 3];
                    case 3: return [2 /*return*/];
                }
            });
        });
    };
    ApiClient.prototype.put = function (path, data, config) {
        return __awaiter(this, void 0, void 0, function () {
            var response, error_3;
            return __generator(this, function (_a) {
                switch (_a.label) {
                    case 0:
                        _a.trys.push([0, 2, , 3]);
                        return [4 /*yield*/, this.axiosInstance.put(path, data, config)];
                    case 1:
                        response = _a.sent();
                        return [2 /*return*/, response.data];
                    case 2:
                        error_3 = _a.sent();
                        this.handleApiError(error_3);
                        return [3 /*break*/, 3];
                    case 3: return [2 /*return*/];
                }
            });
        });
    };
    ApiClient.prototype.delete = function (path, config) {
        return __awaiter(this, void 0, void 0, function () {
            var response, error_4;
            return __generator(this, function (_a) {
                switch (_a.label) {
                    case 0:
                        _a.trys.push([0, 2, , 3]);
                        return [4 /*yield*/, this.axiosInstance.delete(path, config)];
                    case 1:
                        response = _a.sent();
                        return [2 /*return*/, response.data];
                    case 2:
                        error_4 = _a.sent();
                        this.handleApiError(error_4);
                        return [3 /*break*/, 3];
                    case 3: return [2 /*return*/];
                }
            });
        });
    };
    return ApiClient;
}());
exports.ApiClient = ApiClient;
// Example Usage (can be moved to a test file or an example script)
/*
async function main() {
  // Replace with your actual base URL and API key
  const apiClient = new ApiClient('http://localhost:8052/api/v1', 'your-secure-api-key-1');

  try {
    console.log('Listing agents...');
    const agents = await apiClient.get('/agents');
    console.log('Agents:', agents);

    // Example of creating an agent (adjust payload as needed)
    // const newAgentPayload = {
    //   name: "MyTSAgent",
    //   type: "CUSTOM",
    //   abilities: ["ping_ability"],
    // };
    // const newAgent = await apiClient.post('/agents', newAgentPayload);
    // console.log('New Agent:', newAgent);

  } catch (error) {
    if (error instanceof ApiClientError) {
      console.error(`API Error (${error.statusCode}, Code: ${error.errorCode}): ${error.message}`);
      if (error.errorDetails) {
        console.error('Details:', JSON.stringify(error.errorDetails, null, 2));
      }
    } else {
      console.error('Unknown Error:', error);
    }
  }
}

// main();
*/
//# sourceMappingURL=ApiClient.js.map