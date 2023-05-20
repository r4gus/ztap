const std = @import("std");
const fido = @import("../../../main.zig");

/// Verify that the pinUvAuthToken support matches the given parameter
///
/// This covers 1. and 2. of GetAssertion and MakeCredential
///
/// Returns CTAP_ERR_SUCCESS if everything is ok
pub fn verifyPinUvAuthParam(
    auth: *const fido.ctap.authenticator.Authenticator,
    param: anytype,
) fido.ctap.StatusCodes {
    const pinUvAuthTokenSupport = auth.token.one != null or auth.token.two != null;

    // The authenticator supports pinUvAuthToken but the platform sends
    // a zero length pinUvAuthParam
    if (pinUvAuthTokenSupport and param.pinUvAuthParam == null) {
        const permission = auth.callbacks.up(null, null);

        var pin_set = true;
        _ = auth.callbacks.load_pin_hash() catch {
            pin_set = false;
        };

        if (!permission) {
            return fido.ctap.StatusCodes.ctap2_err_operation_denied;
        } else if (permission and !pin_set) {
            return fido.ctap.StatusCodes.ctap2_err_pin_not_set;
        } else {
            return fido.ctap.StatusCodes.ctap2_err_pin_invalid;
        }
    }

    if (param.pinUvAuthParam != null) {
        if (param.pinUvAuthProtocol == null) {
            return fido.ctap.StatusCodes.ctap2_err_missing_parameter;
        } else if (param.pinUvAuthProtocol.? == .V1 and auth.token.one == null) {
            return fido.ctap.StatusCodes.ctap1_err_invalid_parameter;
        } else if (param.pinUvAuthProtocol.? == .V2 and auth.token.two == null) {
            return fido.ctap.StatusCodes.ctap1_err_invalid_parameter;
        }
    }

    return fido.ctap.StatusCodes.ctap1_err_success;
}
