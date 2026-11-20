FROM docker.io/amazon/aws-cli:latest

RUN yum install -y zip && yum clean all

ENTRYPOINT ["bash"]
