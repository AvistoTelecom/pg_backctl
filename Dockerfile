FROM debian:13-slim@sha256:a347fd7510ee31a84387619a492ad6c8eb0af2f2682b916ff3e643eb076f925a AS builder
RUN apt update && apt install -y curl unzip bzip2
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" 
RUN unzip awscliv2.zip
RUN bash ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update


FROM debian:13-slim@sha256:a347fd7510ee31a84387619a492ad6c8eb0af2f2682b916ff3e643eb076f925a
COPY --from=builder /usr/local/aws-cli/ /usr/local/aws-cli/
COPY --from=builder /usr/local/bin/ /usr/local/bin/
COPY --chmod=700 entrypoint.sh /entrypoint.sh
COPY --chmod=700 backup_entrypoint.sh /backup_entrypoint.sh
COPY --chmod=755 lib/ /lib/
COPY --from=builder /bin/bzip2 /bin/bzip2
ENTRYPOINT ["/entrypoint.sh"]
CMD []
