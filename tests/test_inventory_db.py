from types import SimpleNamespace

import pytest

from backend import inventory_db


def _save_scan(db_path: str) -> int:
    result = SimpleNamespace(
        num_items=1,
        distinct_categories=1,
        empty_pct=0.2,
        shelf_type="Category-specific",
        review_count=0,
    )
    records = [
        {
            "crop_id": 1,
            "category": "soft drinks",
            "subcategory": "cola",
            "score": 0.1,
            "area": 100,
            "box": [1, 2, 10, 20],
            "sku_text": "ACME COLA",
            "sku_needs_review": 0,
        }
    ]
    return inventory_db.save_scan(result, "shelf.jpg", records, db_path)


def test_givenDetectedProduct_whenSavingCategoryAndSkuFeedback_thenBothArePersisted(tmp_path):
    db_path = str(tmp_path / "inventory.db")
    scan_id = _save_scan(db_path)

    inventory_db.save_feedback(
        scan_id, 1, "category", "incorrect", "soft drinks > cola", db_path=db_path
    )
    inventory_db.save_feedback(scan_id, 1, "sku", "correct", db_path=db_path)

    feedback = inventory_db.get_feedback_df(db_path)
    assert len(feedback) == 2
    assert set(feedback["feedback_type"]) == {"category", "sku"}
    assert feedback.loc[feedback["feedback_type"] == "category", "correction"].iloc[0] == (
        "soft drinks > cola"
    )


def test_givenExistingFeedback_whenSubmittingReplacement_thenLatestVerdictIsKept(tmp_path):
    db_path = str(tmp_path / "inventory.db")
    scan_id = _save_scan(db_path)
    inventory_db.save_feedback(scan_id, 1, "sku", "incorrect", "SKU-123", db_path=db_path)

    inventory_db.save_feedback(scan_id, 1, "sku", "correct", db_path=db_path)

    feedback = inventory_db.get_feedback_df(db_path)
    assert len(feedback) == 1
    assert feedback.iloc[0]["verdict"] == "correct"
    assert feedback.iloc[0]["correction"] == ""


def test_givenUnknownProduct_whenSavingFeedback_thenRaisesValueError(tmp_path):
    db_path = str(tmp_path / "inventory.db")
    inventory_db.init_db(db_path)

    with pytest.raises(ValueError, match="does not exist"):
        inventory_db.save_feedback(999, 1, "category", "incorrect", db_path=db_path)
