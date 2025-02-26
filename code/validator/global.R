# Libraries ----
library(shiny)
#library(googlesheets4)
library(dplyr)
library(DT)
library(shinythemes)
library(shinyWidgets)
library(validate)
library(digest)
library(data.table)
library(bs4Dash)
library(ckanr)
library(purrr)
library(shinyjs)
library(sentimentr)
library(listviewer)
library(httr)

#Note for logic using outside functions in the calls. 
#https://github.com/data-cleaning/validate/issues/45

# Options ----
options(shiny.maxRequestSize = 30*1024^2)

# Files ----

rules_example <- read.csv("www/rules.csv")

invalid_example <- read.csv("www/invalid_data.csv")

success_example <- read.csv("www/data_success.csv")

# Functions ----


validate_data <- function(files_data, file_rules = NULL){
    if (!grepl("(\\.csv$)", ignore.case = T, as.character(file_rules))) {
        #reset("file")
        return(list(
            message = data.table(
                title = "Data type not supported!",
                text = paste0("Uploaded data type is not currently supported; please upload a .csv file."),
                type = "warning"), status = "error"))
    }
    
    rules <- read.csv(file_rules)
    
    if (!all(c("name", "description", "severity", "rule") %in% names(rules))) {
        #reset("file")
        return(list(
            message = data.table(
                title = "Data type not supported!",
                text = paste0('Uploaded rules format is not currently supported, please provide a rules file with column names, "name", "description", "severity", "rule"'),
                type = "warning"), status = "error"))
    }
    
    if (!all(unlist(lapply(rules, class)) %in% c("character"))) {
        #reset("file")
        return(list(
            message = data.table(
                title = "Data type not supported!",
                text = paste0('Uploaded rules format is not currently supported, please provide a rules file with columns that are all character type.'),
                type = "warning"), status = "error"))
    }
    
    # Read in data when uploaded based on the file type
    if (!all(grepl("(\\.csv$)", ignore.case = T, as.character(files_data)))) {
        return(list(
            message = data.table(
            title = "Data type not supported!",
            text = paste0("Uploaded data type is not currently supported; please
                      upload a .csv file."),
            type = "warning"), status = "error"))
    }
    if(is.null(rules)) {
        return(list(
            message = data.table(
            title = "Need Rules File",
            text = paste0("You must upload a rules file before uploading a data file to validate."),
            type = "warning"), status = "error"))
    }
    data_formatted <- tryCatch(lapply(files_data, function(x) read.csv(x)) %>% 
                         reduce(full_join),
                            warning = function(w) {w}, error = function(e) {e})
    
    if (inherits(data_formatted, "simpleWarning") | inherits(data_formatted, "simpleError")){
        return(list(
            message = data.table(
            title = "Something went wrong with the merge.",
            text = paste0("This tool expects at least one column in each dataset with the same name to merge on. There was also an error that said ", data_formatted$message),
            type = "error"),
            status = "error"
                )
            )
    }
    
    do_to_all <- rules %>%
        filter(grepl("___", rule))
    
    if(nrow(do_to_all) > 0){
            rules <- lapply(colnames(data_formatted), function(new_name){
                do_to_all %>%
                    mutate(rule = gsub("___", new_name, rule)) %>%
                    mutate(name = paste0(new_name, "_", name))
            }) %>%
                rbindlist(.) %>%
                bind_rows(rules %>% filter(!grepl("___", rule)))
    }
   
    
    rules_formatted <- tryCatch(validator(.data=rules), 
                                warning = function(w) {w}, 
                                error = function(e) {e})
    
    if (length(class(rules_formatted)) != 1 || class(rules_formatted) != "validator"){
        return(list(
            message = data.table(
                title = "Something went wrong with reading the rules file.",
                text = paste0("There was an error that said ", rules_formatted$message),
                type = "error"
            ), status = "error"
        ))
    }
    
    if(!all(variables(rules_formatted) %in% names(data_formatted)) | !all(names(data_formatted) %in% variables(rules_formatted))){
        warning_2 <- data.table(
                        title = "Rules and data mismatch",
                        text = paste0("All variables in the rules csv (", paste(variables(rules_formatted)[!variables(rules_formatted) %in% names(data_formatted)], collapse = ", "), ") need to be in the data csv (",  paste(names(data_formatted)[!names(data_formatted) %in% variables(rules_formatted)], collapse = ", "), ") and vice versa for the validation to work."),
                        type = "warning")
    }
    report <- confront(data_formatted, rules_formatted)
    
    results <- summary(report) %>%
        mutate(status = ifelse(fails > 0 | error | warning , "error", "success")) %>%
        left_join(meta(rules_formatted))
    
    return(list(data_formatted = data_formatted, 
                report = report, 
                results = results, 
                rules = rules_formatted, 
                status = "success", 
                message = if(exists("warning_2")){warning_2} else{NULL}))
}


remote_share <- function(data_formatted, api, rules, results){
    if(any(results$status == "error")){
        return(list(
            message = data.table(
            title = "Errors Prevent Upload",
            text = "There are errors in the dataset that persist. Until all errors are remedied, the data cannot be uploaded to the remote repository.",
            type = "error"), status = "error"))
    }
    if(any(unlist(lapply(data_formatted %>% select(-KEY), function(x) any(x %in% unique(data_formatted$KEY)))))){
        return(list(
            message = data.table(
            title = "Secret Key is misplaced",
            text = "The secret key is in locations other than the KEY column, please remove the secret key from any other locations.",
            type = "error"), status = "error"))
    }
    if(length(unique(data_formatted$KEY)) != 1){
        return(list(
            message = data.table(
            title = "Multiple Secret Keys",
            text = paste0("There should only be one secret key per data upload, but these keys are in the data (", paste(unique(data_formatted$KEY), collapse = ","), ")"),
            type = "error"), status = "error"))
    }
    if(!any(unique(data_formatted$KEY) %in% api$VALID_KEY)){
        return(list(
            message = data.table(
            title = "Secret Key is not valid",
            text = "Any column labeled KEY is considered a secret key and should have a valid pair in our internal database.",
            type = "error"), status = "error"))
    }
    if(!any(digest(as.data.frame(rules) %>% select(-created)) %in% api$VALID_RULES)){
        return(list(
            message = data.table(
            title = "Rules file is not valid",
            text = "If you are using a key column to upload data to a remote repo then there must be a valid pair with the rules you are using in our internal database.",
            type = "error"), status = "error"))
    }
    api_info <- api %>%
        dplyr::filter(VALID_KEY == unique(data_formatted$KEY) & VALID_RULES == digest(as.data.frame(rules) %>% select(-created)))
    
    if(nrow(api_info) != 1){
        return(list(
            message = data.table(
            title = "Mismatched rules file and KEY column",
            text = "The secret key and rules file must be exact matches to one another. One secret key is for one rules file.",
            type = "error"), status = "error"))
    }
    
    ckanr_setup(url = api_info$URL, key = api_info$KEY)
    hashed_data <- digest(data_formatted)
    #hashed_rules <- digest(rules)
    #package_version <- packageVersion("validate")
    file <- tempfile(pattern = "data", fileext = ".csv")
    write.csv(data_formatted %>% select(-KEY), file, row.names = F)
    creation <- resource_create(package_id = api_info$PACKAGE,
                                        description = "validated raw data upload to microplastic data portal",
                                        name = paste0("data_", hashed_data),
                                        upload = file)
    return(list(creation = creation, status = "success"))
}


rules_broken <- function(results, show_decision){
    results %>%
        dplyr::filter(if(show_decision){status == "error"} else{status %in% c("error", "success")}) %>%
        select(description, status, name, expression, everything())
}

rows_for_rules <- function(data_formatted, report, broken_rules, rows){
    violating(data_formatted, report[broken_rules[rows, "name"]])
}

#acknowledgement https://github.com/adamjdeacon/checkLuhn/blob/master/R/checkLuhn.R
checkLuhn <- function(number) {
    # must have at least 2 digits
    if(nchar(number) <= 2) {
        return(FALSE)
    }
    
    # strip spaces
    number <- gsub("-", "", gsub(pattern = " ", replacement = "", number))
    
    # Return FALSE if not a number
    if (!grepl("^[[:digit:]]+$", number)) {
        return(FALSE)
    }
    
    # split the string, convert it to a list, and reverse it
    digits <- unlist(strsplit(number, ""))
    digits <- digits[length(digits):1]
    
    to_replace <- seq(2, length(digits), 2)
    digits[to_replace] <- as.numeric(digits[to_replace]) * 2
    
    # gonna do some maths, let's convert it to numbers
    digits <- as.numeric(digits)
    
    # a digit cannot be two digits, so any that are greater than 9, subtract 9 and
    # make the world a better place
    digits <- ifelse(digits > 9, digits - 9, digits)
    
    # does the sum divide by 10?
    ((sum(digits) %% 10) == 0)
}

#PII Checkers ----
#https://www.servicenow.com/community/developer-articles/common-regular-expressions-and-cheat-sheet/ta-p/2297106
#https://support.milyli.com/docs/resources/regex/financial-regex
# ihateregex.io
## Checked

bad_words <- unique(tolower(c(lexicon::profanity_alvarez, 
                              lexicon::profanity_arr_bad, 
                              lexicon::profanity_banned, 
                              lexicon::profanity_zac_anger, 
                              lexicon::profanity_racist)))

license_plate <- "^[0-9A-Z]{3}([^ 0-9A-Z]|\\s)?[0-9]{4}$"
address <- "[1-9][0-9]{0,5}\\s+[A-Za-z0-9\\s]+\\s+(St|Rd|Ct|Ave|Blvd|Way)" #https://pe.usps.com/text/pub28/28apc_002.htm
email <- "[[:alnum:].-]+@[[:alnum:].-]+" #^([a-zA-Z0-9_\-\.]+)@([a-zA-Z0-9_\-\.]+)\.([a-zA-Z]{2,5})$
national_id <- "[0-9]{3}-[0-9]{2}-[0-9]{4}"
ip <- "(?:(25[0-5]|2[0-4]\\d|[01]?\\d{1,2})\\.){3}\\1"#"^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$" #
ip6 <- "(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))" #"^([\\d\\w]{4}|0)(\\:([\\d\\w]{4}|0)){7}$"
phone_number <- "^[\\+]?[(]?[0-9]{3}[)]?[-\\s\\.]?[0-9]{3}[-\\s\\.]?[0-9]{4,6}$"#"\\d{3}?[.-]? *\\d{3}[.-]? *[.-]?\\d{4}"
amexcard <- "^3[47][0-9]{13}$"
mastercard <- "^(?:5[1-5][0-9]{2}|222[1-9]|22[3-9][0-9]|2[3-6][0-9]{2}|27[01][0-9]|2720)[0-9]{12}$"
visacard <- "^([4]\\d{3}[\\s]\\d{4}[\\s]\\d{4}[\\s]\\d{4}|[4]\\d{3}[-]\\d{4}[-]\\d{4}[-]\\d{4}|[4]\\d{3}[.]\\d{4}[.]\\d{4}[.]\\d{4}|[4]\\d{3}\\d{4}\\d{4}\\d{4})$"
zip <- "^((\\d{5}-\\d{4})|(\\d{5})|([A-Z]\\d[A-Z]\\s\\d[A-Z]\\d))$" #^[0-9]{5}(?:-[0-9]{4})?$
url <- "(((ftp|http|https):\\/\\/)|(www\\.))([-\\w\\.\\/#$\\?=+@&%_:;]+)"
iban <- "[a-zA-Z]{2}[0-9]{2}[a-zA-Z0-9]{4}[0-9]{7}([a-zA-Z0-9]?){0,16}" #"(?:(?:IT|SM)\\d{2}[\\w]\\d{22}|CY\\d{2}[\\w]\\d{23}|NL\\d{2}[\\w]{4}\\d{10}|LV\\d{2}[\\w]{4}\\d{13}|(?:BG|BH|GB|IE)\\d{2}[\\w]{4}\\d{14}|GI\\d{2}[\\w]{4}\\d{15}|RO\\d{2}[\\w]{4}\\d{16}|KW\\d{2}[\\w]{4}\\d{22}|MT\\d{2}[\\w]{4}\\d{23}|NO\\d{13}|(?:DK|FI|GL|FO)\\d{16}|MK\\d{17}|(?:AT|EE|KZ|LU|XK)\\d{18}|(?:BA|HR|LI|CH|CR)\\d{19}|(?:GE|DE|LT|ME|RS)\\d{20}|IL\\d{21}|(?:AD|CZ|ES|MD|SA)\\d{22}|PT\\d{23}|(?:BE|IS)\\d{24}|(?:FR|MR|MC)\\d{25}|(?:AL|DO|LB|PL)\\d{26}|(?:AZ|HU)\\d{27}|(?:GR|MU)\\d{28})"
time <- "^(?:2[0-3]|[01]?\\d):[0-5]\\d$"#"[0-9]?[0-9]:[0-9][0-9]"
currency <- "^(.{1})?\\d+(?:\\.\\d{2})?(.{1})?$"
file_info <- "(\\\\[^\\\\]+$)|(/[^/]+$)"
dates <- "^([1][12]|[0]?[1-9])[\\/-]([3][01]|[12]\\d|[0]?[1-9])[\\/-](\\d{4}|\\d{2})$" #(?:(?:31(\/|-|\.)(?:0?[13578]|1[02]))\1|(?:(?:29|30)(\/|-|\.)(?:0?[13-9]|1[0-2])\2))(?:(?:1[6-9]|[2-9]\d)?\d{2})$|^(?:29(\/|-|\.)0?2\3(?:(?:(?:1[6-9]|[2-9]\d)?(?:0[48]|[2468][048]|[13579][26])|(?:(?:16|[2468][048]|[3579][26])00))))$|^(?:0?[1-9]|1\d|2[0-8])(\/|-|\.)(?:(?:0?[1-9])|(?:1[0-2]))\4(?:(?:1[6-9]|[2-9]\d)?\d{2})
amex_visa_mastercard <- "^((4\\d{3}|5[1-5]\\d{2}|2\\d{3}|3[47]\\d{1,2})[\\s\\-]?\\d{4,6}[\\s\\-]?\\d{4,6}?([\\s\\-]\\d{3,4})?(\\d{3})?)$"
column_names <- "(^.*(firstname|fname|lastname|lname|fullname|fname|maidenname|_name|nickname|name_suffix|name|email|e-mail|mail|age|birth|date_of_birth|dateofbirth|dob|birthday|date_of_death|dateofdeath|death|medic|employ|position|financ|educat|income|gender|sex|race|religion|nationality|address|city|state|county|country|zipcode|postal|phone|card|license|security|location|date|latitude|longitude|login|ip).*$)|(^.*user(id|name|).*$)|(^.*pass.*$)|(^.*(ssn|social).*$)"
discover_card <- "^65[4-9][0-9]{13}|64[4-9][0-9]{13}|6011[0-9]{12}|(622(?:12[6-9]|1[3-9][0-9]|[2-8][0-9][0-9]|9[01][0-9]|92[0-5])[0-9]{10})$"
union_card <- "^(62[0-9]{14,17})$"
usa_routing_number <- "^((0[0-9])|(1[0-2])|(2[1-9])|(3[0-2])|(6[1-9])|(7[0-2])|80)([0-9]{7})$"
swift_code <- "^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$"

## Not checked or not working.
bs_global_card <- "^(6541|6556)[0-9]{12}$"
carte_card <- "^389[0-9]{11}$"
diners_card <- "^3(?:0[0-5]|[68][0-9])[0-9]{11}$"
insta_card <- "^63[7-9][0-9]{13}$"
jbc_card <- "^(?:2131|1800|35\\d{3})\\d{11}$"
korea_card <- "^9[0-9]{15}$"
laser_card <- "^(6304|6706|6709|6771)[0-9]{12,15}$"
maestro_card <- "^(5018|5020|5038|6304|6759|6761|6763)[0-9]{8,15}$"
solo_card <- "^(6334|6767)[0-9]{12}|(6334|6767)[0-9]{14}|(6334|6767)[0-9]{15}$"
switch_card <- "^(4903|4905|4911|4936|6333|6759)[0-9]{12}|(4903|4905|4911|4936|6333|6759)[0-9]{14}|(4903|4905|4911|4936|6333|6759)[0-9]{15}|564182[0-9]{10}|564182[0-9]{12}|564182[0-9]{13}|633110[0-9]{10}|633110[0-9]{12}|633110[0-9]{13}$"
argentina_id <- "^\\d{2}\\.\\d{3}\\.\\d{3}$"
canada_passport <- "^[\\w]{2}[\\d]{6}$"
croatia_id <- "^HR\\d{11}$"
cz_id <- "^CZ\\d{8,10}$"
denmark_id <- "^\\d{10}|\\d{6}[-\\s]\\d{4}$"
france_id <- "^\\b\\d{12}\\b$"
insee_pass <- "^\\d{13}|\\d{13}\\s\\d{2}$"
france_dl <- "^\\d{12}$"
france_pass <- "^\\d{2}11\\d{5}$"
german_id <- "^l\\d{8}$"
german_pass <- "^[cfghjk]\\d{3}\\w{5}\\d$"
german_dl <- "^[\\d\\w]\\d{2}[\\d\\w]{6}\\d[\\d\\w]$"
netherlands_bsn <- "^\\d{8}|\\d{3}[-\\.\\s]\\d{3}[-\\.\\s]\\d{3}$"
poland_id <- "^\\d{11}$"
portugal_id <- "^\\d{9}[\\w\\d]{2}|\\d{8}-\\d[\\d\\w]{2}\\d$"
spain_ssn <- "^\\d{2}\\/?\\d{8}\\/?\\d{2}$"
sweden_pass <- "^\\d{8}$"
uk_pass <- "^\\d{9}$"
uk_dl <- "^[\\w9]{5}\\d{6}[\\w9]{2}\\d{5}$"
uk_health_num <- "^\\d{3}\\s\\d{3}\\s\\d{4}$"

grepl(license_plate, "NT5-6345")

#AI Generated
#Social Security Numbers: \\b(\\d{3}[-\\.\\s]??\\d{2}[-\\.\\s]??\\d{4})\\b
#Phone Numbers: \\b(\\d{3}[-\\.\\s]??\\d{3}[-\\.\\s]??\\d{4}|\\(?\\d{3}\\)?[-\\.\\s]??\\d{3}[-\\.\\s]??\\d{4})\\b
#Email Addresses: \\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,6}\\b
#Names: \\b[A-Z][a-z]*\\s[A-Z][a-z]*\\b
#Addresses: \\b[0-9]{1,6}\\s[A-Za-z0-9\\s]*(St|Rd|Ave|Blvd|Way)\\b

## Checks
#profanity(bad_words[1], bad_words)
#profanity("hat", bad_words)
#grepl(license_plate, "NT5-6345")
#grepl(email, "cowger@gmail.com")
#grepl(national_id, "612-49-2884")
#grepl(ip, "192.168.1.1")
#grepl(phone_number, "15153725233")
#grepl(amexcard, "372418640982660")
#grepl(mastercard, "5258704108753590")
#grepl(visacard, "4563-7568-5698-4587")
#grepl(amex_visa_mastercard, "372418640982660")
#grepl(amex_visa_mastercard, "5258704108753590")
#grepl(amex_visa_mastercard, "4563-7568-5698-4587")
#grepl(zip, "92501")
#grepl(url, "https:\\www.wincowger.com")
#grepl(iban, "NL02ABNA0123456789")
#grepl(time, "23:00")
#grepl(currency, "5000.00$")
#grepl(file_info, "the\\shdhfdk\\test.csv")
#grepl(file_info, "the/shdhfdk/test.csv")
#grepl(dates, "12-20-2020")
#grepl(column_names, "birthday", ignore.case = T)
#grepl(discover_card, "6011266701973605")
#grepl(union_card, "6226984208995522")
#checkLuhn("6011-266701-973605")
#checkLuhn("6226984208995522")
#grepl(usa_routing_number, "122105155")
#grepl(swift_code, "WFBIUS6BXXX")
#grepl(address, " 123 Main ct ", ignore.case = T) 

#Not working
#grepl(diners_card, "3036614767651300") 
#grepl(ip6, "2001:0db8:0001:0000:0000:0ab9:C0A8:0102") #Not working. 
#grepl(birthday, "birthday: 11-30-1992")

#Profanity


#Tests ----

#setwd("G:/My Drive/MooreInstitute/Projects/PeoplesLab/Code/Microplastic_Data_Portal/code/validator/secrets")

#Material_PA <= 1| Material_PA %vin% c("N/A") | Material_PA %vin% ("Present")
#api <- read.csv("ckan.csv")
#file_data = "G:/My Drive/MooreInstitute/Projects/PeoplesLab/Code/Microplastic_Data_Portal/data/Clean_DrinkingWater_Data/Samples_Merged.csv"
#files_rules = "G:/My Drive/MooreInstitute/Projects/PeoplesLab/Code/Microplastic_Data_Portal/data/Clean_DrinkingWater_Data/Validation_Rules_Samples_Merged.csv"
#files_data = "G:/My Drive/MooreInstitute/Projects/PeoplesLab/Code/Microplastic_Data_Portal/data/AccreditedLabs/PII.csv"
#files_rules = "G:/My Drive/MooreInstitute/Projects/PeoplesLab/Code/Microplastic_Data_Portal/data/AccreditedLabs/PII_Rules.csv"


#list_complaints <- lapply(1:nrow(files_rules), function(x){
#    tryCatch(validator(.data=files_rules[x,]), 
#             warning = function(w) {w}, 
#             error = function(e) {e})
#})

#rules_formatted <- tryCatch(validator(.data=rules), 
#                            warning = function(w) {w}, 
#                            error = function(e) {e})

#test_rules <- validate_rules(files_rules)
#test_data <- validate_data(files_data = file_data, rules = test_rules$rules)
#variables(test_rules$rules)[variables(test_rules$rules) != "DOI"]
#(test_data$data_formatted$Approximate_Lattitude == "N/A" | suppressWarnings(as.numeric(test_data$data_formatted$Approximate_Lattitude) > -90 & as.numeric(test_data$data_formatted$Approximate_Lattitude) < 90)) & !is.na(test_data$data_formatted$Approximate_Lattitude)
#test_rules$message
#test_data$status
#test_data$results
#test_data$data_formatted$Approximate_Lattitude
#test_bad_rules <- validate_rules("rules.txt")
#test_remote <- remote_share(data_formatted = test_data$data_formatted, api = api, rules = test_rules$rules, results = test_data$results)
#test_rules_2 <- validate_rules("C:/Users/winco/Downloads/rules (14).csv")
#test_invalid <- validate_data(files_data = "C:/Users/winco/Downloads/invalid_data (3).csv", rules = test_rules_2$rules)
#test_rules_broken <- rules_broken(results = test_invalid$results, show_decision = T)
#test_rows <- rows_for_rules(data_formatted = test_invalid$data_formatted, report = test_invalid$report, broken_rules = test_rules_broken, rows = 1)
#RIP LIL PEEP TEST BY GABRIEL