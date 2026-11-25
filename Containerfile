FROM docker.io/amazon/aws-cli:latest

ARG TERRAFORM_VERSION=1.10.5

RUN yum install -y zip unzip openssl && \
    ARCH="$(uname -m)" && \
    case "${ARCH}" in \
      x86_64) TF_ARCH="amd64" ;; \
      aarch64|arm64) TF_ARCH="arm64" ;; \
      *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TF_ARCH}.zip" -o /tmp/terraform.zip && \
    unzip -o /tmp/terraform.zip -d /usr/local/bin && \
    rm -f /tmp/terraform.zip && \
    terraform version && \
    yum clean all

ENTRYPOINT ["bash"]
