from clipboard_sync_server import parse_request_text


def test_form_repeated_text_fields_join_with_crlf():
    body = "text=one.png&text=two%20name.png&text=three%2C_%7Bchar%7D+s-123.png"
    assert parse_request_text(body, "application/x-www-form-urlencoded") == "one.png\r\ntwo name.png\r\nthree,_{char} s-123.png"


def test_form_single_text_field_stays_single_text():
    body = "text=nsfw%2C1girl%2C_%7B%7B%7Bmikasa+ackerman%7D%7D%7D+s-196339520.png"
    assert parse_request_text(body, "application/x-www-form-urlencoded") == "nsfw,1girl,_{{{mikasa ackerman}}} s-196339520.png"


def test_json_list_joins_with_crlf():
    body = '{"text":["one.png","two.png"]}'
    assert parse_request_text(body, "application/json") == "one.png\r\ntwo.png"


def test_plain_body_passes_through():
    assert parse_request_text("raw 😅 text", "text/plain") == "raw 😅 text"


if __name__ == "__main__":
    for test in (
        test_form_repeated_text_fields_join_with_crlf,
        test_form_single_text_field_stays_single_text,
        test_json_list_joins_with_crlf,
        test_plain_body_passes_through,
    ):
        test()
    print("4 parser tests passed")
