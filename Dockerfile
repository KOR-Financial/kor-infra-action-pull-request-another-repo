FROM denys1yermakov/alpine:latest

#All next steps base image already contain 
# FROM alpine:3
# RUN apk update && \
#     apk upgrade && \
#     apk add git && \
#     apk add go && \
#     apk add make && \
#     git clone https://github.com/cli/cli.git gh-cli && \
#     cd gh-cli && \
#     make && \
#     apk add bash && \
#     mv ./bin/gh /usr/local/bin/

ADD entrypoint.sh /entrypoint.sh

ENTRYPOINT [ "/entrypoint.sh" ]
