## Install python If exsite
FROM debian:12 AS builder
RUN apt update && apt install -y curl unzip
## Install fucking binary AWS CLI If existe
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" 
RUN unzip awscliv2.zip
RUN bash ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update


FROM debian:12
COPY --from=builder /usr/local/aws-cli/ /usr/local/aws-cli/
COPY --from=builder /usr/local/bin/ /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh", ""]