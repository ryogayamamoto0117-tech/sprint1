import boto3
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

kms = boto3.client("kms")

with open("infra/sprint6/tfplan.key.enc", "rb") as f:
    encrypted_key = f.read()

response = kms.decrypt(
    CiphertextBlob=encrypted_key,
    KeyId="alias/terraform-plan"
)

plaintext_key = response["Plaintext"]

with open("infra/sprint6/tfplan.enc", "rb") as f:
    encrypted_plan = f.read()

with open("infra/sprint6/tfplan.nonce", "rb") as f:
    nonce = f.read()

aesgcm = AESGCM(plaintext_key)
plan_data = aesgcm.decrypt(nonce, encrypted_plan, None)

with open("infra/sprint6/tfplan", "wb") as f:
    f.write(plan_data)