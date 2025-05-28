# To run this script, you will need:
# - Java 11+
# - openapi-generator-cli.jar, which can be downloaded from https://openapi-generator.tech/docs/installation/#jar

JARNAME="openapi-generator-cli.jar"

if [ ! -f "$JARNAME" ]; then
    echo "Missing $JARNAME. Please download it from https://openapi-generator.tech/docs/installation/#jar"
    exit 1
fi

java -jar $JARNAME generate \
    -i ./julia/src/api/spec/api-spec.yaml \
    -g julia-server \
    -o ./julia/src/api/server \
    --additional-properties=packageName=CutePanelServer \
    --additional-properties=exportModels=true