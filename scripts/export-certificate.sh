#!/bin/bash

# Script to export Developer ID Application certificate as .p12
# This exports both the certificate and private key together

set -e

# Certificate name pattern - adjust if your certificate name differs
CERT_NAME_PATTERN="Developer ID Application"
OUTPUT_FILE="developer-id-cert.p12"

echo "🔐 Exporting Developer ID Application certificate..."
echo "Looking for certificate matching: $CERT_NAME_PATTERN"
echo ""

# Find the certificate hash
CERT_HASH=$(security find-identity -v -p codesigning | grep "$CERT_NAME_PATTERN" | head -1 | sed 's/.*\([0-9A-F]\{40\}\).*/\1/')

if [ -z "$CERT_HASH" ]; then
    echo "❌ Error: Certificate not found!"
    echo "Available certificates:"
    security find-identity -v -p codesigning | grep "Developer ID"
    exit 1
fi

# Get full certificate name for display
FULL_CERT_NAME=$(security find-identity -v -p codesigning | grep "$CERT_HASH" | sed 's/.*"\(.*\)".*/\1/')
echo "Found certificate: $FULL_CERT_NAME"
echo "Certificate hash: $CERT_HASH"
echo ""

# Export as .p12
echo "Please enter a password for the .p12 file (this will be your P12_PASSWORD):"
read -s P12_PASSWORD
echo ""
echo "Confirm password:"
read -s P12_PASSWORD_CONFIRM
echo ""

if [ "$P12_PASSWORD" != "$P12_PASSWORD_CONFIRM" ]; then
    echo "❌ Error: Passwords don't match!"
    exit 1
fi

# Export the certificate and private key
echo "📦 Exporting certificate and private key..."
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"
security export -k "$KEYCHAIN_PATH" -t identities -f pkcs12 -P "$P12_PASSWORD" -o "$OUTPUT_FILE" "$CERT_HASH" 2>&1 || {
    echo ""
    echo "⚠️  First method failed. Trying alternative method..."
    
    # Alternative: Export using openssl (requires certificate and key separately)
    CERT_FILE="/tmp/cert.pem"
    KEY_FILE="/tmp/key.pem"
    
    # Export certificate
    security find-certificate -c "$FULL_CERT_NAME" -a -p > "$CERT_FILE"
    
    # Try to find and export the private key
    # This might require the keychain password
    echo "Please enter your Mac login password (for keychain access):"
    security find-certificate -c "$FULL_CERT_NAME" -a -p | openssl pkcs12 -export -out "$OUTPUT_FILE" -passout pass:"$P12_PASSWORD" -nokeys 2>/dev/null || {
        echo ""
        echo "❌ Could not export private key automatically."
        echo ""
        echo "📋 Manual steps:"
        echo "1. Open Keychain Access"
        echo "2. Select 'login' keychain (left sidebar)"
        echo "3. Search for '$FULL_CERT_NAME'"
        echo "4. Expand the certificate (click arrow)"
        echo "5. Select BOTH the certificate AND the private key (Cmd+Click)"
        echo "6. Right-click → Export 2 items..."
        echo "7. Choose .p12 format"
        echo "8. Set password: $P12_PASSWORD"
        exit 1
    }
}

if [ -f "$OUTPUT_FILE" ]; then
    echo "✅ Certificate exported successfully: $OUTPUT_FILE"
    echo ""
    echo "📋 Next steps:"
    echo "1. Base64 encode the certificate:"
    echo "   base64 -i $OUTPUT_FILE | pbcopy"
    echo ""
    echo "2. Add to GitHub Secrets:"
    echo "   BUILD_CERTIFICATE_BASE64: <paste the base64 string>"
    echo "   P12_PASSWORD: $P12_PASSWORD"
else
    echo "❌ Export failed!"
    exit 1
fi
