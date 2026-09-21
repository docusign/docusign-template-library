// This file contains Docusign Power BI Data Connector logic with dynamic parameters
[Version = "2.0.0"]
section Docusign;

// Global timeout for Web.Contents requests (15 minutes)
requestTimeout = #duration(0, 0, 15, 00);

// Client name and version for headers
clientNameHeaderValue = "DS-PBI-Connector";
clientVersionHeaderValue = "2.0";

[DataSource.Kind = "Docusign", DataSource.Path = "Environment={0}", Publish = "Docusign.Publish"]
shared Docusign.Contents = Value.ReplaceType(DocusignImpl, DocusignType);

DocusignType = type function (
environment as (type text meta [
Documentation.FieldCaption = "Environment",
Documentation.AllowedValues = { "Demo", "Prod" }
]),
accountId as (type text meta [
Documentation.FieldCaption = "Account id",
Documentation.FieldDescription = "Account id",
Documentation.SampleValues = {"12b571d6-c662-4d3d-9d42-efa88073ea19"}
]))
as table meta [
Documentation.Name = "Docusign Connector",
Documentation.LongDescription = "Custom connector for connection to Docusign services",
Documentation.Examples = {[
Description = "Connector for connecting to docusign service"
]}
];

Docusign.GetErrorMessage = (responseJson as any, fallbackMessage as text) as text =>
    let
        errorRecord =
            if Value.Is(responseJson, type record) then
                Record.FieldOrDefault(responseJson, "error", null)
            else
                null,
        apiMessage =
            if errorRecord <> null and Value.Is(errorRecord, type record) then
                Text.From(Record.FieldOrDefault(errorRecord, "message", fallbackMessage))
            else
                fallbackMessage
    in
        apiMessage;

Docusign.GetJsonWithHandledErrors = (url as text, accessToken as text, userLocale as text) as any =>
    let
        response = Web.Contents(url, [
            Headers = [
                #"Authorization" = "Bearer " & accessToken,
                #"X-Locale" = userLocale,
                #"X-Client-Name" = clientNameHeaderValue,
                #"X-Client-Version" = clientVersionHeaderValue
            ],
            Timeout = requestTimeout,
            ManualStatusHandling = {403}
        ]),
        responseMetadata = Value.Metadata(response),
        statusCode = Record.FieldOrDefault(responseMetadata, "Response.Status", 200),
        responseJson = try Json.Document(response) otherwise null,
        result =
            if statusCode = 403 then
                let
                    serviceMessage = Docusign.GetErrorMessage(responseJson, "An unexpected error occurred. Please try again later.")
                in
                error Error.Record(
                    "DocusignForbidden",
                    serviceMessage,
                    [
                        StatusCode = statusCode,
                        ServiceMessage = serviceMessage
                    ]
                )
            else
                responseJson
    in
        result;

DocusignImpl = (environment as text, accountId as text) as table =>
    let
        accessToken = GetToken(),

        // Get user's system locale/culture with fallback
        userLocale = try Culture.Current otherwise "en-US",

        oDataBaseUrl = Config(environment)[ODataBaseUrl],

        metadataUrl = oDataBaseUrl  & "/accounts/" & accountId & (if Text.Lower(environment) <> "exp" then "/analytics" else "") & "/datasets",
        metadataResponse = Docusign.GetJsonWithHandledErrors(metadataUrl, accessToken, userLocale),

        datasetList = metadataResponse[value],

        // Transform metadata into records with Name and TableName
        datasetRecords = List.Transform(datasetList, each [
            Name = if Record.Field(_, "TableName") = null or Record.Field(_, "TableName") = ""
                        then Record.Field(_, "Name")
                        else Record.Field(_, "TableName"),
            Data = Docusign.CallAnalyticsAPI(environment, oDataBaseUrl, accountId, Record.Field(_, "Name"), datasetList, userLocale)
        ]),

        // Build navigation table
        navigationTable = Table.FromRecords(datasetRecords, type table [Name = text, Data = table]),
        navTable = Table.ToNavigationTable(navigationTable, {"Name"}, "Name", "Data", "Table", "ItemName", "IsLeaf")
    in
        navTable;

shared Docusign.CallAnalyticsAPI = (environment as text,oDataBaseUrl as text, accountId as text, datasetName as text, datasetList as list, userLocale as text) =>
    let
        // Find the matching dataset record
        datasetmetadata = List.First(List.Select(datasetList, each Record.Field(_, "Name") = datasetName)),

        chunkSize = datasetmetadata[ChunkSize],
        maxChunks = datasetmetadata[MaxChunks],
        paginationOrderByClause = datasetmetadata[OrderByClause],

        firstChunk = Docusign.AnalyticsAPICaller(environment, oDataBaseUrl, accountId, datasetName, datasetmetadata, userLocale, 0, chunkSize),
        CombinedChunks =
            if Text.Length(paginationOrderByClause) < 1 or Table.RowCount(firstChunk) = 0 or Table.RowCount(firstChunk) < chunkSize then // Perform pagination only when pagination order by clause is present.
                firstChunk
            else
                let
                    LoopChunks = List.Generate(
                        () => [i = 1, data = firstChunk],
                        each [i] < maxChunks and Table.RowCount([data]) > 0,
                        each [
                            i = [i] + 1,
                            data = Docusign.AnalyticsAPICaller(
                                environment,
                                oDataBaseUrl,
                                accountId,
                                datasetName,
                                datasetmetadata,
                                userLocale,
                                [i] * chunkSize,
                                chunkSize
                            )
                        ],
                        each [data]
                    )
                in
                    Table.Combine(LoopChunks)
    in
        CombinedChunks;

shared Docusign.AnalyticsAPICaller = (environment as text, oDataBaseUrl as text, accountId as text, datasetName as text, datasetmetadata as record, userLocale as text, skip as number, chunkSize as number) =>
    let
        accessToken = GetToken(),

        paginationOrderByClause = datasetmetadata[OrderByClause],

        pagenateQuery =
            if Text.Length(paginationOrderByClause) > 0
            // Perform pagination only when pagination order by clause is present, or consider it does not require pagination.
            then "?&" & paginationOrderByClause & "&$skip="& Text.From(skip) & "&$top=" & Text.From(chunkSize)
            else "",

        urlWithQuery = oDataBaseUrl  & "/accounts/" & accountId &  (if Text.Lower(environment) <> "exp" then "/analytics" else "") & "/datasets/" & datasetName & "/records" & pagenateQuery,

        // Make HTTP request and parse response
        dataJson = Docusign.GetJsonWithHandledErrors(urlWithQuery, accessToken, userLocale),
        asTable = Table.FromRecords(dataJson [value]),

         // Extract the Fields array
        fieldsArray = datasetmetadata[Fields],

        // Transform to desired format
        allFields = List.Transform(fieldsArray, each [
            name = Record.Field(_, "Name"),
            type = Record.Field(_, "Type")
        ]),

    // Remove records with empty/null type
    nonEmptyFields = List.Select(allFields, each Text.Trim(Text.From(Record.Field(_, "type"))) <> ""),

    // Remove duplicates (based on both name and type)
    fieldInfo = List.Distinct(nonEmptyFields),

    typeFromText = (typeName as text) as type =>
    let
        lowerTypeName = Text.Lower(typeName),
        typeMap = [
            int = Int32.Type,
            int32 = Int32.Type,
            integer = Int32.Type,
            long = Int64.Type,
            int64 = Int64.Type,
            string = type text,
            datetime = type datetime,
            date = type date,
            double = type number,
            bool = type logical,
            boolean = type logical
        ],
        result = Record.FieldOrDefault(typeMap, lowerTypeName, type text)
    in
        result,

    columnTypes = Record.FromList(
            List.Transform(fieldInfo, each typeFromText(_[type])),
            List.Transform(fieldInfo, each _[name])
        ),

    // Remove the '@odata.type' column if it exists
    cleanedTable =
            if List.Contains(Table.ColumnNames(asTable), "@odata.type")
            then
                Table.RemoveColumns(asTable, {"@odata.type"})
            else
                asTable,

    resultTable = if Table.ColumnCount(cleanedTable) = 0 then
        Table.TransformColumnTypes(
            #table(Record.FieldNames(columnTypes), {}),
            List.Zip({Record.FieldNames(columnTypes), Record.ToList(columnTypes)})
        )
    else
        let
            actualColumns = Table.ColumnNames(cleanedTable),
            desiredColumns = Record.FieldNames(columnTypes),

            // Only use types from columnTypes if the column exists
            appliedColumnTypes =
                List.Transform(
                    desiredColumns,
                    each if List.Contains(actualColumns, _) then
                        {_, Record.Field(columnTypes, _)}
                    else
                        {_, type text}
                ),

            typedTable = Table.TransformColumnTypes(cleanedTable, appliedColumnTypes)
        in
            typedTable

    in
        resultTable;

// Set config based on environment.
Config = (environment as text) as record =>
let
    configText = Text.FromBinary(Extension.Contents("config.json")),
    configRecord = Json.Document(configText),
    configRaw = Record.FieldOrDefault(configRecord, environment),
    config = if configRaw = null then
        error Error.Record("InvalidEnvironment", "Environment not found: " & environment)
    else
        configRaw
in
    config;

// Helper function to create a Navigation Table structure
Table.ToNavigationTable = (
    table as table,
    keyColumns as list,
    nameColumn as text,
    dataColumn as text,
    itemKindColumn as text,
    itemNameColumn as text,
    isLeafColumn as text
) as table =>
    let
        tableType = Value.Type(table),
        newTableType = Type.AddTableKey(tableType, keyColumns, true) meta [
            NavigationTable.NameColumn = nameColumn,
            NavigationTable.DataColumn = dataColumn,
            NavigationTable.ItemKindColumn = itemKindColumn,
            Preview.DelayColumn = itemNameColumn,
            NavigationTable.IsLeafColumn = isLeafColumn
        ],
        navigationTable = Value.ReplaceType(table, newTableType)
    in
        navigationTable;

// OAuth2 Authentication setup
redirect_uri = "https://oauth.powerbi.com/views/oauthredirect.html";
state = "test";

windowHeight = 800;
windowWidth = 800;

// The sample provides two code_challenge_method examples: "plain" and "S256".
code_challenge_method = "S256";

// Start OAuth login flow
StartLogin = (resourceUrl, state, display) =>
    let
        // Parse the environment from the resourceUrl, e.g., "Environment=Exp"
        inputData = Json.Document(resourceUrl),
        environment = inputData[environment],

        baseAuthorizeUrl = Config(environment)[BaseAuthorizeUrl],
        clientId = Config(environment)[ClientId],

        code_verifier = Text.NewGuid() & Text.NewGuid(),
        code_challenge =
            if (code_challenge_method = "plain") then
                code_verifier
            else if (code_challenge_method = "S256") then
                Base64Url.Encode(Crypto.CreateHash(CryptoAlgorithm.SHA256, Text.ToBinary(code_verifier)))
            else
                error "Unexpected code_challenge_method",
        AuthorizeUrl = baseAuthorizeUrl
            & Uri.BuildQueryString(
                [
                    response_type = "code",
                    client_id = clientId,
                    scope = "lens_api signature extended user_read",
                    state = state,
                    code_challenge_method = code_challenge_method,
                    code_challenge = code_challenge,
                    redirect_uri = redirect_uri
                ]
            ),
        windowHeight = 700,
        windowWidth = 700
    in
        [
            LoginUri = AuthorizeUrl,
            CallbackUri = redirect_uri,
            WindowHeight = windowHeight,
            WindowWidth = windowWidth,
            Context = code_verifier
        ];

// Finalize OAuth login and obtain the token
FinishLogin = (clientApplication, resourceUrl, context, callbackUri, state) =>
    let
        Parts = Uri.Parts(callbackUri)[Query]
    in
        TokenMethod(resourceUrl, "authorization_code", Parts[code], context);

Refresh = (resourceUrl, refresh_token) => TokenMethod(resourceUrl, "refresh_token", refresh_token);

// Token exchange method
TokenMethod = (resourceUrl, grant_type, code, optional code_verifier) =>
    let
        // Parse the environment from the resourceUrl, e.g., "Environment=Exp"
        inputData = Json.Document(resourceUrl),
        environment = inputData[environment],

        clientId = Config(environment)[ClientId],
        tokenUrl = Config(environment)[TokenUrl],

        // Construct the body based on the grant type
        body =
            if grant_type = "authorization_code" then
                Uri.BuildQueryString(
                    [
                        grant_type = "authorization_code",
                        code = code,
                        code_verifier = code_verifier,
                        client_id = clientId
                    ]
                )
            else if grant_type = "refresh_token" then
                Uri.BuildQueryString([
                    grant_type = "refresh_token",
                    refresh_token = code,
                    client_id = clientId
                ])
            else
                error "Unsupported grant_type",
        // Send the token request
        Response = Web.Contents(
            tokenUrl,
            [
                Content = Text.ToBinary(body),
                Headers = [
                    #"Content-type" = "application/x-www-form-urlencoded",
                    #"Accept" = "application/json"
                ]
            ]
        ),
        // Parse the JSON response
        Parts = Json.Document(Response),
        access_tok = Parts[access_token],
        refresh_tok = Parts[refresh_token],
        sco = Parts[scope],
        outpo = [
            access_token = access_tok,
            refresh_token = refresh_tok,
            expires_in = Parts[expires_in],
            scope = sco
        ]
    in
        outpo;

GetToken = () =>
    let
        existingToken = Extension.CurrentCredential(), access_token = existingToken[access_token]
    in
        access_token;

// Data Source Kind description (authentication)
Docusign = [
    TestConnection = (dataSourcePath) => 
        let
            // dataSourcePath is a JSON string sent by the Gateway
            json = Json.Document(dataSourcePath),
            environment = if Record.HasFields(json, "environment") then json[environment] else json[Environment],
            accountId = if Record.HasFields(json, "accountId") then json[accountId] else json[AccountId]
        in
            { "Docusign.Contents", environment, accountId },

    Authentication = [
        OAuth2 = [
            StartLogin = StartLogin,
            FinishLogin = FinishLogin,
            Refresh = Refresh
        ]
    ],
    Label = Extension.LoadString("DataSourceLabel")
];

// Data Source UI publishing description
Docusign.Publish = [
    Beta = true,
    Category = "Other",
    ButtonText = {Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp")},
    LearnMoreUrl = "https://powerbi.microsoft.com/",
    SourceImage = Docusign.Icons,
    SourceTypeImage = Docusign.Icons
];

// Icon definitions for the connector UI
Docusign.Icons = [
    Icon16 = {
        Extension.Contents("Docusign16.png"),
        Extension.Contents("Docusign20.png"),
        Extension.Contents("Docusign24.png"),
        Extension.Contents("Docusign32.png")
    },
    Icon32 = {
        Extension.Contents("Docusign32.png"),
        Extension.Contents("Docusign40.png"),
        Extension.Contents("Docusign48.png"),
        Extension.Contents("Docusign64.png")
    }
];

Base64Url.Encode = (s) =>
    Text.Replace(
        Text.Replace(Text.BeforeDelimiter(Binary.ToText(s, BinaryEncoding.Base64), "="), "+", "-"), "/", "_"
    );
