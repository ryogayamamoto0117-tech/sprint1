import boto3
import os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

kms = boto3.client("kms")

response = kms.generate_data_key(
    KeyId="alias/terraform-plan",
    KeySpec="AES_256"
)

plaintext_key = response["Plaintext"]
encrypted_key = response["CiphertextBlob"]

nonce = os.urandom(12)

with open("infra/sprint6/tfplan", "rb") as f:
    plan_data = f.read()

aesgcm = AESGCM(plaintext_key)
encrypted_plan = aesgcm.encrypt(nonce, plan_data, None)

with open("infra/sprint6/tfplan.enc", "wb") as f:
    f.write(encrypted_plan)

with open("infra/sprint6/tfplan.key.enc", "wb") as f:
    f.write(encrypted_key)

with open("infra/sprint6/tfplan.nonce", "wb") as f:
    f.write(nonce)

os.remove("infra/sprint6/tfplan")