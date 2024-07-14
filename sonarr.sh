#!/usr/bin/env bash

# load env file from $NTFY_ENV or script dir
SCRIPTPATH=${NTFY_ENV:-$(dirname "$0")/.env}
[ -f ${SCRIPTPATH} ] && . "${SCRIPTPATH}" || echo "ENV missing: ${SCRIPTPATH}"

# Function to retrieve the banner image for a series from Sonarr API. Parameters are taken from env file
# Outputs series banner_image URL for use in ntfy_post_data()
get_banner_image()
{
  headers_file=$(mktemp)
  response_file=$(mktemp)

  response_body=$(curl -s -D "$headers_file" -o "$response_file" -H "Content-Type: application/json" -H "X-Api-Key: $sonarr_api_key" "$sonarr_url/api/v3/series/$sonarr_series_id")
  response_code=$(grep HTTP/ "$headers_file" | awk '{print $2}')  # get the status code from the headers
  if [[ $response_code -ne 200 ]]; then
    >&2 echo "Failed to retrieve banner image. Response code $response_code"
    exit 1
  fi
  banner_image=$(jq -r '.images[0].remoteUrl // empty' "$response_file")
  if [[ -z "$banner_image" ]]; then
    >&2 echo "Banner image not found"
    exit 2
  fi
  rm "$headers_file" "$response_file"
}

# Check if ntfy_username and ntfy_password OR ntfy_token are set.
# If both are set, print an error message and exit with code 1
# If only one is set, set the ntfy_auth variable accordingly
if [[ -n $ntfy_password && -n $ntfy_token ]]; then
  >&2 echo "Use ntfy_username and ntfy_password OR ntfy_token"
  exit 3
elif [ -n "$ntfy_password" ]; then
  ntfy_base64=$( echo -n "$ntfy_username:$ntfy_password" | base64 )
  ntfy_auth="Authorization: Basic $ntfy_base64"
elif [ -n "$ntfy_token" ]; then
  ntfy_auth="Authorization: Bearer $ntfy_token"
else
  ntfy_auth=""
fi

# Sets the appropriate values for the notification title, message, and tag based on the Sonarr event type.
ntfy_title="$sonarr_series_title"
ntfy_message=" "
if [ "$sonarr_eventtype" == "Test" ]; then
  ntfy_tag=information_source
  ntfy_title="Testing"
elif [ "$sonarr_eventtype" == "Grab" ]; then
  get_banner_image # Call get_banner_image function to retrieve the banner image for the series
  ntfy_tag=tv
  ntfy_title="$ntfy_title - S$sonarr_release_seasonnumber:E$sonarr_release_episodenumbers"
  ntfy_message="- $sonarr_release_episodetitles [$sonarr_release_quality]"
elif [ "$sonarr_eventtype" == "Download" ]; then
  get_banner_image # Call get_banner_image function to retrieve the banner image for the series
  ntfy_tag=tv
  ntfy_title="$ntfy_title - S$sonarr_episodefile_seasonnumber:E$sonarr_episodefile_episodenumbers"
  ntfy_message="- $sonarr_episodefile_episodetitles [$sonarr_episodefile_quality]"
elif [ "$sonarr_eventtype" == "ApplicationUpdate" ]; then
  ntfy_tag=arrow_up
  ntfy_message="Sonarr updated from $sonarr_update_previousversion to $sonarr_update_newversion"
elif [ "$sonarr_eventtype" == "HealthIssue" ]; then
  ntfy_tag=warning
  ntfy_message="$sonarr_health_issue_message"
else
  ntfy_tag=information_source
fi

# Generates JSON data for sending to ntfy.
# If the value of "sonarr_eventtype" is "Download", include additional fields for attaching a banner image and a link to the TVDB website.
# Otherwise, generate JSON data without these additional fields.
if [[ "$sonarr_eventtype" == "Download" || "$sonarr_eventtype" == "Grab" ]]; then
ntfy_post_data()
{
  cat <<EOF
{
  "topic": "$sonarr_ntfy_topic",
  "tags": ["$ntfy_tag"],
  "icon": "$sonarr_ntfy_icon",
  "attach": "$banner_image",
  "title": "Sonarr: $sonarr_eventtype",
  "message": "$ntfy_title$ntfy_message",
  "actions": [
    {
      "action": "view",
      "label": "TVDB",
      "url": "https://www.thetvdb.com/dereferrer/series/$sonarr_series_tvdbid",
      "clear": true
    }
  ]
}
EOF
}
else
ntfy_post_data()
{
  cat <<EOF
{
  "topic": "$sonarr_ntfy_topic",
  "tags": ["$ntfy_tag"],
  "icon": "$sonarr_ntfy_icon",
  "title": "Sonarr: $sonarr_eventtype",
  "message": "$ntfy_title$ntfy_message"
}
EOF
}
fi

#Sends a POST request to ntfy with the JSON data generated by ntfy_post_data.
response=$(curl -s -o /dev/null -w "%{http_code}" -H "Accept: application/json" \
     -H "Content-Type:application/json" \
     -H "$ntfy_auth" -X POST --data "$(ntfy_post_data)" "$ntfy_url")

# If the response code is 200, the notification was sent successfully.
# Otherwise, print an error message and exit with code 4.
if [[ "$response" -eq 200 ]]; then
  echo "Notification sent successfully"
else
  >&2 echo "Failed to send notification. Response code: $response"
  exit 4
fi
